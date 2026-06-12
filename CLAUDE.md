# CLAUDE.md

이 파일은 Claude Code가 이 저장소에서 작업할 때 참고하는 프로젝트 안내서입니다.
설계 배경·결정 이유·해결한 버그·남은 작업(백로그)은 `HANDOFF.md`에 있습니다 —
새 기능을 시작하거나 "왜 이렇게 되어 있지?"가 궁금할 때 먼저 읽어 보세요.

## 프로젝트 개요

**claude-lachesis** — Claude Code의 플랜 사용량을 '추정'해 보여 주는 macOS 메뉴 막대 앱.

- `~/.claude/projects/**/*.jsonl`(Claude Code 대화 기록)만 읽어서
  현재 세션(5시간) · 이번 주(전체) · 이번 주(Sonnet) 사용률을 계산한다.
- **네트워크 접근 금지가 핵심 설계 원칙이다.** Anthropic 서버나 비공식
  엔드포인트(`/api/oauth/usage` 등)를 호출하는 코드를 절대 추가하지 않는다.
  이는 이용약관 준수를 위한 의도적 제약이다.
- 퍼센트는 **추정치**다. 한도(분모)는 비공개이므로 역대 최대 사용량(자동)
  또는 사용자 입력(수동)을 분모로 쓴다. 이 한계를 UI에서 숨기지 않는다
  ("추정" 배지, 안내 문구 유지).

## 빌드 / 실행

```bash
brew install xcodegen      # 최초 1회 (없을 때만)
xcodegen generate          # project.yml → Lachesis.xcodeproj 생성
open Lachesis.xcodeproj     # Xcode 16+ 필요(아래 참고), ⌘R로 실행
```

- **`.xcodeproj`는 `project.yml`(XcodeGen)에서 생성하는 산출물이다.** 직접
  편집하지 말고 git에서도 무시한다(`.gitignore`). 빌드 설정·파일 목록을
  바꾸려면 `project.yml`을 고친 뒤 `xcodegen generate`를 다시 돌린다.
- 대상: macOS 13 (Ventura) 이상. **macOS 14+ 전용 API를 쓰지 말 것.**
- 메뉴 막대 전용 앱: `INFOPLIST_KEY_LSUIElement = YES` (빌드 설정에서 처리,
  Info.plist 파일 없음 — `GENERATE_INFOPLIST_FILE = YES`).
- **앱 샌드박스는 의도적으로 꺼져 있다.** `~/.claude`를 읽어야 하므로
  켜면 안 된다. App Store 배포 형식이 아니다.
- 서명: `CODE_SIGN_IDENTITY = "-"` (로컬 실행용).

## 아키텍처

```
Lachesis/
├── LachesisApp.swift    # @main. MenuBarExtra(.window) + 메뉴 막대 라벨(실시간 %)
├── ContentView.swift    # 팝오버 UI: 사용량 카드 3장, CapsuleBar, 푸터
├── SettingsView.swift   # 설정 시트: 한도 기준(자동/수동), 주간 초기화 시각
├── UsageStore.swift     # @MainActor ObservableObject. 1분 타이머로 갱신,
│                        #   @AppStorage 설정 보관, 포맷 도우미(fmt*)
└── UsageEngine.swift    # 순수 계산 계층. JSONL 스캔 → UsageEvent →
                         #   5시간 구간/주간 창 집계 → WindowEstimate
```

데이터 흐름: `UsageStore.refresh()` → `Task.detached`에서
`UsageEngine.compute(config:)` 실행 → `MainActor`에서 `@Published`에 반영
→ ContentView와 메뉴 막대 라벨이 갱신.

### 추정 로직의 핵심 규칙 (UsageEngine.swift)

- **세션 구간**: 첫 메시지 시각에 시작, 정확히 5시간 뒤 종료. 이벤트가
  구간 끝 이후면 그 이벤트 시각으로 새 구간 시작. (시각 반올림 없음)
- **토큰 합산**: input + output + cache_creation + **cache_read×0.1** 가중합.
  cache_read(캐시 읽기)는 매 호출마다 같은 컨텍스트를 다시 읽어 양이 압도적이라
  (실측 95%), Anthropic 과금 체계(캐시 읽기 = 입력의 0.1배)에 맞춰 0.1배로
  가중한다. 전액 합산하면 /usage 실제 퍼센트의 약 3배로 과대 추정된다
  (2026-06-11 스크린샷 검증). 이 가중치를 1.0으로 되돌리지 말 것.
- **중복 제거**: `message.id + "|" + requestId` 키로 dedup. JSONL에는 같은
  응답이 여러 줄로 남을 수 있으므로 이 로직을 제거하면 안 된다.
- **주간 창**: 항상 '매주 초기화' 앵커 기준이다. 설정에서 "초기화 시각 직접
  설정"을 켜면 사용자가 지정한 요일·시각, 끄면 **기본값(월요일 오전 10시 =
  defaultAnchorWeekday/Minutes)** 을 쓴다. compute()와 maxWeeklyTotals() 두
  곳이 같은 기준을 쓰게 유지할 것(갈라지면 한도 계산이 어긋난다). '최근 7일'
  이동 창 모드는 제거됨.
- **자동 한도**: 세션 = 역대 최대 5시간 구간 합계, 주간 = 역대 최대 주간
  합계. 항상 현재 사용량 이상이 되도록 `max(관찰최대, 현재)` 처리
  (100% 초과 방지).
- **소진 속도/도달 예측**: 최근 1시간(구간이 짧으면 구간 시작부터)의 토큰으로
  시간당 속도를 계산. 관찰 시간 5분 미만이면 표시하지 않음. 도달 예상 시각은
  초기화 이전일 때만 노출(초과 시 "여유" 문구). 세션 카드 전용.
- **임계값 알림**: 70/90% 도달 시 UserNotifications로 1회 알림.
  중복 방지 키 = `notified.{창}.{초기화시각 epoch}.{임계값}` (UserDefaults).
  주간 창은 이제 항상 초기화 시각이 있지만, 앵커 계산이 드물게 실패해
  resetsAt이 nil이면 '오늘 자정'을 도장으로 폴백한다.

## 동시성 규칙 (충돌 방지)

- `UsageStore.refresh()`는 **재진입 금지**: `guard !isLoading`으로 이전 스캔이
  끝나기 전 재실행을 막는다. 이 가드를 제거하면 백그라운드 스캔이 겹쳐
  EXC_BAD_ACCESS가 날 수 있다.
- `ISO8601DateFormatter`는 **공유 static으로 두지 말 것**. 스캔마다 지역
  변수로 생성한다 (동시 사용 시 안전이 보장되지 않음).
- 엔진은 미래 시각 기록을 걸러내고(`date <= now+60s`), 소진 속도 계산은
  `elapsed` 음수 방지와 `rate.isFinite` 검사를 유지한다.

## 프로젝트 파일 관련 주의 (XcodeGen)

- **`.xcodeproj`는 손으로 관리하지 않는다.** `project.yml`이 진실원본이고,
  `xcodegen generate`가 `Lachesis.xcodeproj`를 만든다. `.xcodeproj`는
  `.gitignore` 대상(생성물)이다. pbxproj를 직접 편집하면 다음 생성 때 덮어쓰인다.
- **새 Swift 파일을 추가**하려면 `Lachesis/`에 파일을 두고 `xcodegen generate`만
  돌리면 된다. (예전의 pbxproj 4곳 수동 등록 — `PBXFileReference` /
  `PBXBuildFile` / 그룹 children / Sources phase — 은 더 이상 필요 없다.)
- 빌드 설정·번들 ID·서명·LSUIElement 등을 바꾸려면 pbxproj가 아니라
  **`project.yml`을 고친 뒤 재생성**한다. `info:` 블록은 쓰지 말 것 — 실제
  Info.plist 파일이 생겨 "Info.plist 파일 없음" 원칙이 깨진다. LSUIElement는
  `INFOPLIST_KEY_LSUIElement` 빌드 설정으로 유지한다.
- **objectVersion 은 77**이다. XcodeGen 2.45 가 77로 하드코딩하며 옵션으로
  못 낮춘다. 그래서 **빌드에 Xcode 16 이상이 필요**하다(런타임 대상은 여전히
  macOS 13). XcodeGen 은 폴더 동기화(synchronized group) 형식은 쓰지 않으니
  소스 그룹은 전통적 PBXGroup 으로 생성된다.

## 코드 컨벤션

- 주석과 UI 문자열은 **한국어**, 쉬운 단어 사용. 어려운 용어는 괄호로 풀이.
- UI 디자인 언어: "터미널 계기판" — 숫자·제목은 monospaced, 슬레이트 트랙
  위 하늘색 채움, 임계색 전환은 70%(주황) / 90%(빨강). 임의로 바꾸지 말 것.
- **리퀴드 글래스 (macOS 26+)**: 카드 배경·배지·바닥글 버튼은
  ContentView.swift 하단의 전환 부품(GlassCardBackground,
  EstimateBadgeBackground, FooterButtonStyle, GlassCardStack)을 통해서만
  글래스를 적용한다. 새 글래스 요소를 추가할 때도 반드시
  `#if compiler(>=6.2)` + `if #available(macOS 26.0, *)` 이중 가드와
  평면 폴백을 함께 둘 것 — macOS 13~15와 구형 Xcode 호환이 깨지면 안 된다.
  글래스 위 텍스트 대비가 낮아지면 채움 막대 색은 글래스 처리하지 않는다
  (막대는 정보이므로 항상 불투명 유지).
- macOS 13 호환 함정:
  - `Text(...) + Text(...)` 연결에 `foregroundStyle`을 쓰지 말 것
    (macOS 14+에서만 Text 반환). HStack으로 대체한다.
  - `@AppStorage`는 ObservableObject 안에서 **변경 알림을 발행하지 않는다.**
    그래서 UsageStore는 자체 `@AppStorage`(같은 키)를 refresh 시점에 **읽기만**
    한다. 이 읽기 구조는 유지할 것.
  - **설정 편집은 '초안 → 적용' 모델이다.** SettingsView는 로컬 `@State` 초안을
    편집하고, '적용' 버튼을 누를 때만 `@AppStorage`(같은 키)에 커밋한 뒤
    `store.refresh()`를 부른다. 좌상단 닫기 버튼으로 닫으면 커밋하지 않으므로
    변경이 원복되고, `onAppear`가 저장값을 다시 불러온다. 즉시 저장(live
    binding)으로 되돌리지 말 것 — 닫기=원복이 깨진다.
- 설정 키(UserDefaults): `limitMode`, `manualSessionLimitM`,
  `manualWeeklyLimitM`, `manualSonnetWeeklyLimitM`, `weeklyAnchorEnabled`,
  `weeklyAnchorWeekday`(1=일…7=토), `weeklyAnchorMinutes`(자정 기준 분),
  `notificationsEnabled`, `notifyThresholdLow`(%, 기본 70),
  `notifyThresholdHigh`(%, 기본 90).
  키 이름을 바꾸면 기존 사용자 설정이 초기화되므로 바꾸지 말 것.

## 앱 아이콘

- `make_icon.py`(Python + Pillow)로 생성:
  `python3 make_icon.py` → `Lachesis/Assets.xcassets/AppIcon.appiconset/`에
  16~1024px PNG 출력. 디자인 변경 시 이 스크립트를 수정해 재생성한다.

## 검증 체크리스트 (코드 수정 후)

- [ ] macOS 13 API만 사용했는가?
- [ ] 네트워크 호출이 추가되지 않았는가?
- [ ] 새 파일/설정 변경 후 `xcodegen generate`로 .xcodeproj를 다시 만들었는가?
- [ ] "추정" 배지·안내 문구가 유지되는가?
- [ ] dedup 로직이 손상되지 않았는가?
