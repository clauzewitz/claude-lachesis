import Foundation

// ─────────────────────────────────────────────────────────────
// 추정 엔진
//
// 클로드 코드가 ~/.claude/projects/ 에 남기는 대화 기록(.jsonl)에서
// 토큰 사용량을 읽어, 5시간 세션 구간과 주간 창의 '추정' 사용률을
// 계산합니다. 정확한 한도(분모)는 공개되어 있지 않으므로,
// "지금까지 관찰된 최대 사용량"을 한도로 삼거나(자동),
// 사용자가 직접 입력한 값을 씁니다(수동).
//
// 이 앱은 네트워크에 전혀 접근하지 않습니다.
// ─────────────────────────────────────────────────────────────

/// 응답 한 번에 대한 토큰 사용 기록입니다.
struct UsageEvent: Sendable {
    let date: Date
    let model: String
    let tokens: Int          // 입력+출력+캐시생성 + 캐시읽기×0.1 (과금 체계 정렬 가중합)
    var isSonnet: Bool { model.lowercased().contains("sonnet") }
}

/// 하나의 사용량 창(세션/주간)에 대한 추정 결과입니다.
struct WindowEstimate: Sendable {
    let usedTokens: Int       // 이번 창에서 쓴 토큰
    let limitTokens: Int      // 한도(추정 또는 수동 입력)
    let windowStart: Date?    // 이번 창의 집계 시작 시각 (기준점)
    let resetsAt: Date?       // 초기화 예정 시각 (모르면 nil)
    let isActive: Bool        // 세션 전용: 지금 활성 구간인지
    let burnPerHour: Int?     // 최근 소진 속도 (시간당 토큰, 세션 전용)
    let depleteAt: Date?      // 이 속도면 한도에 닿을 것으로 예상되는 시각
    var dailyTokens: [Int] = []  // 주간 전용: weekStart부터 하루 단위 7칸 (스파크라인용)

    var percent: Double {
        guard limitTokens > 0 else { return 0 }
        return min(100, Double(usedTokens) / Double(limitTokens) * 100)
    }
}

/// 엔진이 한 번 계산을 마치면 내놓는 결과 묶음입니다.
struct EngineResult: Sendable {
    var session: WindowEstimate?
    var weekAll: WindowEstimate?
    var weekSonnet: WindowEstimate?
    var fileCount = 0
    var eventCount = 0
    var error: String? = nil
}

/// 한도를 정하는 방식입니다.
enum LimitMode: String, CaseIterable, Identifiable {
    case auto = "auto"        // 역대 최대 사용량을 한도로 추정
    case manual = "manual"    // 사용자가 직접 입력
    var id: String { rawValue }
    var label: String { self == .auto ? "자동 추정" : "직접 입력" }
}

/// 엔진에 넘기는 설정값입니다. (설정 화면에서 저장한 값)
struct EngineConfig: Sendable {
    var limitMode: LimitMode = .auto
    var manualSessionLimitM: Double = 0      // 단위: 백만 토큰
    var manualWeeklyLimitM: Double = 0
    var manualSonnetWeeklyLimitM: Double = 0
    var weeklyAnchorEnabled: Bool = true     // 주간 초기화 시각 적용 여부 (기본: 켬)
    var weeklyAnchorWeekday: Int = 2         // 1=일 … 7=토 (기본: 월요일)
    var weeklyAnchorMinutes: Int = 10 * 60   // 자정 기준 분 (기본: 오전 10:00)
}

enum UsageEngine {

    static let fiveHours: TimeInterval = 5 * 3600
    static let sevenDays: TimeInterval = 7 * 24 * 3600

    // 주간 초기화 토글이 꺼져 있을 때 쓰는 기본 앵커 (월요일 오전 10시).
    static let defaultAnchorWeekday = 2     // 1=일 … 7=토 → 월요일
    static let defaultAnchorMinutes = 600   // 자정 기준 분 → 오전 10:00

    // MARK: 진입점

    static func compute(config: EngineConfig) -> EngineResult {
        var result = EngineResult()

        let (events, fileCount, error) = scanEvents()
        result.fileCount = fileCount
        result.eventCount = events.count
        if let error { result.error = error; return result }
        let now = Date()
        // 시계가 어긋났거나 손상된 기록에 '미래 시각'이 섞여 있으면
        // 구간 계산이 꼬일 수 있으므로 안전하게 걸러냅니다.
        let sorted = events
            .filter { $0.date <= now.addingTimeInterval(60) }
            .sorted { $0.date < $1.date }
        guard !sorted.isEmpty else {
            result.error = "사용 기록이 아직 없습니다.\nClaude Code로 대화를 진행하면 표시됩니다."
            return result
        }

        // ── 5시간 세션 구간 나누기
        // 구간은 '첫 메시지 시각'에 시작해 정확히 5시간 뒤에 끝납니다.
        var blocks: [(start: Date, total: Int)] = []
        var blockStart = sorted[0].date
        var blockTotal = 0
        for e in sorted {
            if e.date >= blockStart.addingTimeInterval(fiveHours) {
                blocks.append((blockStart, blockTotal))
                blockStart = e.date
                blockTotal = 0
            }
            blockTotal += e.tokens
        }
        blocks.append((blockStart, blockTotal))

        let last = blocks[blocks.count - 1]
        let sessionActive = now < last.start.addingTimeInterval(fiveHours)
        let sessionUsed = sessionActive ? last.total : 0
        let maxBlock = blocks.map(\.total).max() ?? 0

        // ── 주간 창 경계 정하기
        // 주간 집계는 항상 '매주 초기화' 앵커 기준입니다.
        // 토글 ON이면 사용자가 지정한 요일·시각, OFF면 기본값(월요일 오전 10시).
        let aWeekday = config.weeklyAnchorEnabled ? config.weeklyAnchorWeekday : defaultAnchorWeekday
        let aMinutes = config.weeklyAnchorEnabled ? config.weeklyAnchorMinutes : defaultAnchorMinutes
        let weekStart: Date
        let weekReset: Date?
        if let anchor = mostRecentAnchor(before: now, weekday: aWeekday, minutes: aMinutes) {
            weekStart = anchor
            weekReset = anchor.addingTimeInterval(sevenDays)
        } else {
            // 앵커 계산 실패(아주 드묾) 시 안전 폴백
            weekStart = now.addingTimeInterval(-sevenDays)
            weekReset = nil
        }

        var weekAllUsed = 0, weekSonnetUsed = 0
        var weekDaily = [Int](repeating: 0, count: 7)   // weekStart부터 하루 단위 7칸
        for e in sorted where e.date >= weekStart && e.date <= now {
            weekAllUsed += e.tokens
            if e.isSonnet { weekSonnetUsed += e.tokens }
            let dayIdx = Int(e.date.timeIntervalSince(weekStart) / 86400)
            if dayIdx >= 0 && dayIdx < 7 { weekDaily[dayIdx] += e.tokens }
        }

        // ── 한도(분모) 정하기
        let sessionLimit: Int
        let weeklyLimit: Int
        let sonnetWeeklyLimit: Int

        switch config.limitMode {
        case .manual:
            sessionLimit = Int(config.manualSessionLimitM * 1_000_000)
            weeklyLimit = Int(config.manualWeeklyLimitM * 1_000_000)
            sonnetWeeklyLimit = Int(config.manualSonnetWeeklyLimitM * 1_000_000)
        case .auto:
            // 자동: 역대 최대 5시간 구간 / 역대 최대 주간 사용량을 한도로 추정합니다.
            sessionLimit = max(maxBlock, sessionUsed)
            let (maxWeekAll, maxWeekSonnet) = maxWeeklyTotals(
                sorted, now: now, config: config)
            weeklyLimit = max(maxWeekAll, weekAllUsed)
            sonnetWeeklyLimit = max(maxWeekSonnet, weekSonnetUsed)
        }

        // ── 소진 속도와 한도 도달 예측 (현재 세션)
        // 최근 1시간(구간이 그보다 짧으면 구간 시작부터)의 토큰 소비로
        // 시간당 속도를 구하고, "이 속도면 언제 한도에 닿는지"를 예측합니다.
        var burnPerHour: Int? = nil
        var depleteAt: Date? = nil
        if sessionActive {
            let sessionReset = last.start.addingTimeInterval(fiveHours)
            let recentStart = max(now.addingTimeInterval(-3600), last.start)
            let elapsed = max(0, now.timeIntervalSince(recentStart))
            if elapsed >= 300 {   // 관찰 시간이 5분 미만이면 속도가 들쭉날쭉하므로 보류
                let recentTokens = sorted
                    .filter { $0.date >= recentStart && $0.date <= now }
                    .reduce(0) { $0 + $1.tokens }
                let rate = Double(recentTokens) / (elapsed / 3600)
                if rate.isFinite && rate > 0 {
                    burnPerHour = Int(rate)
                    let remainingTokens = Double(sessionLimit - sessionUsed)
                    if remainingTokens <= 0 {
                        depleteAt = now   // 이미 추정 한도에 도달
                    } else {
                        let eta = now.addingTimeInterval(remainingTokens / rate * 3600)
                        // 초기화 전에 닿을 때만 경고로 보여줍니다.
                        if eta < sessionReset { depleteAt = eta }
                    }
                }
            }
        }

        result.session = WindowEstimate(
            usedTokens: sessionUsed,
            limitTokens: sessionLimit,
            windowStart: sessionActive ? last.start : nil,
            resetsAt: sessionActive ? last.start.addingTimeInterval(fiveHours) : nil,
            isActive: sessionActive,
            burnPerHour: burnPerHour,
            depleteAt: depleteAt)
        result.weekAll = WindowEstimate(
            usedTokens: weekAllUsed, limitTokens: weeklyLimit,
            windowStart: weekStart, resetsAt: weekReset, isActive: true,
            burnPerHour: nil, depleteAt: nil, dailyTokens: weekDaily)
        result.weekSonnet = WindowEstimate(
            usedTokens: weekSonnetUsed, limitTokens: sonnetWeeklyLimit,
            windowStart: weekStart, resetsAt: weekReset, isActive: true,
            burnPerHour: nil, depleteAt: nil)
        return result
    }

    // MARK: 주간 최대치 (자동 한도용)

    /// 과거 주간 창들 각각의 합계를 구해 가장 큰 값을 돌려줍니다.
    private static func maxWeeklyTotals(_ sorted: [UsageEvent], now: Date,
                                        config: EngineConfig) -> (Int, Int) {
        guard !sorted.isEmpty else { return (0, 0) }

        // 창의 기준점: compute()와 동일하게 항상 앵커 기준
        // (ON=사용자 지정, OFF=기본 월요일 오전 10시). 두 곳이 갈라지면 안 됨.
        let aWeekday = config.weeklyAnchorEnabled ? config.weeklyAnchorWeekday : defaultAnchorWeekday
        let aMinutes = config.weeklyAnchorEnabled ? config.weeklyAnchorMinutes : defaultAnchorMinutes
        let anchor: Date = mostRecentAnchor(before: now, weekday: aWeekday, minutes: aMinutes)
            ?? (Calendar.current.dateInterval(of: .weekOfYear, for: now)?.start ?? now)

        // 각 기록이 몇 번째 주 창에 속하는지 계산해 합산합니다.
        var allByWeek: [Int: Int] = [:]
        var sonnetByWeek: [Int: Int] = [:]
        for e in sorted {
            let idx = Int(floor(e.date.timeIntervalSince(anchor) / sevenDays))
            allByWeek[idx, default: 0] += e.tokens
            if e.isSonnet { sonnetByWeek[idx, default: 0] += e.tokens }
        }
        return (allByWeek.values.max() ?? 0, sonnetByWeek.values.max() ?? 0)
    }

    /// '지금' 이전의 가장 가까운 주간 초기화 시각을 찾습니다.
    /// 예: 매주 월요일 오전 10시 → 지난 월요일 오전 10시
    private static func mostRecentAnchor(before now: Date, weekday: Int,
                                         minutes: Int) -> Date? {
        var cal = Calendar.current
        cal.timeZone = .current
        var comps = DateComponents()
        comps.weekday = weekday
        comps.hour = minutes / 60
        comps.minute = minutes % 60
        // 다음 발생 시각을 찾은 뒤 7일을 빼면 '직전' 발생 시각입니다.
        guard let next = cal.nextDate(after: now, matching: comps,
                                      matchingPolicy: .nextTime) else { return nil }
        return next.addingTimeInterval(-sevenDays)
    }

    // MARK: 파일 스캔

    /// ~/.claude/projects/ 의 모든 .jsonl 파일에서 토큰 기록을 읽습니다.
    private static func scanEvents() -> ([UsageEvent], Int, String?) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let dirs = [
            home.appendingPathComponent(".claude/projects"),
            home.appendingPathComponent("Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/projects")
        ].filter { fm.fileExists(atPath: $0.path) }

        guard !dirs.isEmpty else {
            return ([], 0, "~/.claude/projects 폴더를 찾을 수 없습니다.\nClaude Code로 대화를 한 번 진행하면 생성됩니다.")
        }

        // 날짜 해석기는 스캔마다 새로 만듭니다.
        // (공유 인스턴스를 여러 작업이 동시에 쓰면 충돌할 수 있으므로)
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var events: [UsageEvent] = []
        var seen = Set<String>()   // 같은 기록이 두 번 세어지는 것 방지
        var fileCount = 0

        for dir in dirs {
            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                fileCount += 1
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                content.enumerateLines { line, _ in
                    guard let e = parseLine(line, isoFrac: isoFrac, isoPlain: isoPlain) else { return }
                    if let key = e.key {
                        if seen.contains(key) { return }
                        seen.insert(key)
                    }
                    events.append(e.event)
                }
            }
        }
        return (events, fileCount, nil)
    }

    // MARK: 한 줄(JSON) 해석

    private static func parseLine(_ line: String,
                                  isoFrac: ISO8601DateFormatter,
                                  isoPlain: ISO8601DateFormatter) -> (event: UsageEvent, key: String?)? {
        guard let data = line.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawLine.self, from: data),
              let usage = raw.message?.usage,
              let ts = raw.timestamp,
              let date = isoFrac.date(from: ts) ?? isoPlain.date(from: ts)
        else { return nil }

        // 토큰 가중 합산.
        // cache_read(캐시 읽기)는 매 호출마다 같은 대화 컨텍스트를 다시 읽어
        // 양이 압도적으로 커지는데(실측 95%), Anthropic 과금은 이를 입력의
        // 0.1배로 매긴다. 한도도 비용과 비슷하게 동작한다고 보고 0.1배로 가중해야
        // /usage 의 실제 퍼센트와 맞는다. (전액 합산하면 약 3배 과대 추정됨 —
        // 2026-06-11 /usage 스크린샷으로 검증. 자세한 내용은 HANDOFF.md 참고)
        let total = (usage.input_tokens ?? 0) + (usage.output_tokens ?? 0)
                  + (usage.cache_creation_input_tokens ?? 0)
                  + Int(Double(usage.cache_read_input_tokens ?? 0) * 0.1)
        guard total > 0 else { return nil }

        let event = UsageEvent(date: date,
                               model: raw.message?.model ?? "unknown",
                               tokens: total)
        var key: String? = nil
        if let id = raw.message?.id { key = id + "|" + (raw.requestId ?? "") }
        return (event, key)
    }
}

// JSON 한 줄의 구조 (필요한 부분만 정의)
private struct RawLine: Decodable {
    let timestamp: String?
    let requestId: String?
    let message: RawMessage?
}
private struct RawMessage: Decodable {
    let id: String?
    let model: String?
    let usage: RawUsage?
}
private struct RawUsage: Decodable {
    let input_tokens: Int?
    let output_tokens: Int?
    let cache_creation_input_tokens: Int?
    let cache_read_input_tokens: Int?
}
