import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────
// 메인 화면
// 디자인 컨셉: "터미널 계기판"
// - /usage 화면처럼 모노스페이스 숫자와 캡슐 막대
// - 슬레이트 트랙 + 하늘색 채움 (한도가 가까워지면 주황 → 빨강)
// - 추정치임을 숨기지 않고 배지로 정직하게 표시
// ─────────────────────────────────────────────────────────────

struct ContentView: View {
    @EnvironmentObject var store: UsageStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            header

            if let message = store.statusMessage {
                emptyState(message)
            } else {
                GlassCardStack(spacing: 14) {
                    UsageCard(title: "현재 세션",
                              subtitle: "5시간 창",
                              estimate: store.session,
                              inactiveText: "활성 세션 없음")
                    UsageCard(title: "이번 주",
                              subtitle: "전체 모델",
                              estimate: store.weekAll,
                              inactiveText: nil)
                    UsageCard(title: "이번 주",
                              subtitle: "Sonnet 전용",
                              estimate: store.weekSonnet,
                              inactiveText: nil)
                }
            }

            footnote
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 336)
    }

    // ── 머리글: 앱 이름 + 역할 + '추정' 배지
    private var header: some View {
        HStack(spacing: 8) {
            Text("Lachesis")
                .font(.system(.headline, design: .monospaced))
            Text("Claude Code 사용량")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("추정")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .modifier(EstimateBadgeBackground())
                .foregroundStyle(.orange)
            Spacer()
            if store.isLoading { ProgressView().controlSize(.small) }
        }
    }

    // ── 기록이 없을 때
    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // ── 추정치 설명 한 줄
    private var footnote: some View {
        Text("토큰 기록 기반 추정치로, 공식 수치와 다를 수 있습니다.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // ── 바닥글: 새로 고침 · 갱신 시각 · 설정 · 종료
    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("새로 고침")

            if let updated = store.updatedAt {
                Text(relative(updated))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                openWindow(id: "settings")
                // 보조(LSUIElement) 앱이라 창을 앞으로 끌어올려 줍니다.
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
            }
            .help("설정")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("종료")
        }
        .modifier(FooterButtonStyle())
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ko_KR")
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// ─────────────────────────────────────────────────────────────
// 사용량 카드 한 장: 제목 줄 + 캡슐 막대 + 초기화 시각/토큰
// ─────────────────────────────────────────────────────────────

struct UsageCard: View {
    let title: String
    let subtitle: String
    let estimate: WindowEstimate?
    let inactiveText: String?   // 세션이 비활성일 때 보여줄 글 (nil이면 항상 활성 취급)

    private var isInactive: Bool {
        guard let e = estimate else { return true }
        return !e.isActive && inactiveText != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // 제목 줄: 이름 + 부제 + 큰 퍼센트
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(.subheadline, design: .monospaced).weight(.bold))
                Text(subtitle)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if isInactive {
                    Text(inactiveText ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else if let e = estimate {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(Int(e.percent.rounded()))")
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundStyle(barColor(e.percent))
                        Text("%")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 캡슐 진행 막대
            CapsuleBar(fraction: isInactive ? 0 : (estimate?.percent ?? 0) / 100,
                       color: barColor(estimate?.percent ?? 0))

            // 아랫줄: 초기화 시각·남은 시간 + 사용 토큰
            HStack {
                if isInactive {
                    Text("새 메시지를 보내면 세션이 시작됩니다")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                } else if let e = estimate {
                    if let reset = e.resetsAt {
                        Label(fmtReset(reset) + " 초기화 · " + fmtRemainingUntil(reset) + " 남음",
                              systemImage: "clock.arrow.circlepath")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("최근 7일 이동 창 기준")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(fmtShortTokens(e.usedTokens) + " / " + fmtShortTokens(e.limitTokens))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            // 집계 기준점: 이번 창이 언제부터 세어지고 있는지 투명하게 표시
            if !isInactive, let start = estimate?.windowStart {
                Text(fmtReset(start) + "부터 집계")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            // 소진 속도와 한도 도달 예측 (세션 카드)
            if !isInactive, let e = estimate, let burn = e.burnPerHour {
                HStack(spacing: 4) {
                    Image(systemName: "flame")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    if let eta = e.depleteAt {
                        Text("소진 \(fmtShortTokens(burn))/시 · \(fmtReset(eta)) 한도 도달 예상")
                            .foregroundStyle(.orange)
                    } else {
                        Text("소진 \(fmtShortTokens(burn))/시 · 이 속도면 초기화 전 여유")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(.caption2, design: .monospaced))
            }

            // 주간 일별 스파크라인 (dailyTokens가 있는 카드 = 주간 전체)
            if !isInactive, let daily = estimate?.dailyTokens, !daily.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("일별 사용량")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    WeekSparkline(daily: daily)
                }
            }
        }
        .padding(12)
        .modifier(GlassCardBackground())
    }

    /// 사용률에 따라 막대 색이 변합니다: 파랑 → 주황(70%) → 빨강(90%)
    private func barColor(_ percent: Double) -> Color {
        switch percent {
        case ..<70: return Color(red: 0.58, green: 0.77, blue: 0.96) // 하늘색
        case ..<90: return .orange
        default:    return .red
        }
    }
}

/// 슬레이트 트랙 위에 채움이 차오르는 캡슐 막대입니다.
struct CapsuleBar: View {
    let fraction: Double   // 0.0 ~ 1.0
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(red: 0.24, green: 0.33, blue: 0.44).opacity(0.55)) // 슬레이트 트랙
                Capsule()
                    .fill(color)
                    .frame(width: max(0, geo.size.width * min(1, fraction)))
                    .animation(.easeOut(duration: 0.35), value: fraction)
            }
        }
        .frame(height: 9)
    }
}

/// 주간 일별 사용량 미니 막대 차트 (7칸).
/// 슬레이트 트랙 위에 하늘색 막대 — 카드의 CapsuleBar와 같은 디자인 언어.
struct WeekSparkline: View {
    let daily: [Int]   // weekStart부터 하루 단위 7칸

    private let sky = Color(red: 0.58, green: 0.77, blue: 0.96)
    private let slate = Color(red: 0.24, green: 0.33, blue: 0.44)

    var body: some View {
        let maxVal = max(daily.max() ?? 0, 1)   // 0 나눗셈 방지
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(daily.enumerated()), id: \.offset) { _, value in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(slate.opacity(0.45))
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(sky)
                        .frame(height: max(2, CGFloat(value) / CGFloat(maxVal) * 22))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 22)
    }
}

// ─────────────────────────────────────────────────────────────
// 리퀴드 글래스 지원 (macOS 26 Tahoe 이상)
//
// 두 겹의 안전장치로 어디서나 동작합니다:
// - #if compiler(>=6.2): Xcode 26 미만(글래스 API가 없는 SDK)에서도
//   이 파일이 컴파일되도록 글래스 코드를 빌드에서 제외합니다.
// - if #available(macOS 26.0, *): macOS 26 미만에서 실행될 때는
//   기존 평면 디자인으로 자동 전환합니다.
// ─────────────────────────────────────────────────────────────

/// 사용량 카드의 배경: macOS 26에서는 리퀴드 글래스, 이하에서는 평면.
struct GlassCardBackground: ViewModifier {
    // 브랜드 하늘색(barColor·스파크라인과 동일). 글래스에 은은히 입혀 카드를 앱 색과 통일.
    private let brandSky = Color(red: 0.58, green: 0.77, blue: 0.96)

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(brandSky.opacity(0.07)),
                                in: .rect(cornerRadius: 14))
        } else {
            flat(content)
        }
        #else
        flat(content)
        #endif
    }

    private func flat(_ content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }
}

/// '추정' 배지의 배경: macOS 26에서는 주황 틴트 글래스 캡슐.
struct EstimateBadgeBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(.orange.opacity(0.35)))
        } else {
            flat(content)
        }
        #else
        flat(content)
        #endif
    }

    private func flat(_ content: Content) -> some View {
        content.background(Capsule().fill(Color.orange.opacity(0.18)))
    }
}

/// 바닥글 버튼: macOS 26에서는 글래스 버튼, 이하에서는 테두리 없는 버튼.
struct FooterButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.borderless)
        }
        #else
        content.buttonStyle(.borderless)
        #endif
    }
}

/// 카드 여러 장을 묶는 컨테이너.
/// macOS 26에서는 GlassEffectContainer로 묶어 인접한 유리 도형의
/// 혼합과 렌더링 성능을 시스템이 최적화하게 합니다.
struct GlassCardStack<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                VStack(spacing: spacing) { content() }
            }
        } else {
            VStack(spacing: spacing) { content() }
        }
        #else
        VStack(spacing: spacing) { content() }
        #endif
    }
}
