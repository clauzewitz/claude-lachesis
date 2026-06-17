import Foundation
import SwiftUI
import Combine
import UserNotifications

/// 설정값을 보관하고, 1분마다 추정 엔진을 돌려 결과를 화면에 공급합니다.
@MainActor
final class UsageStore: ObservableObject {

    // ── 화면에 보여줄 결과
    @Published var session: WindowEstimate?
    @Published var weekAll: WindowEstimate?
    @Published var weekSonnet: WindowEstimate?
    @Published var statusMessage: String?
    @Published var updatedAt: Date?
    @Published var isLoading = false

    // ── 설정 (앱을 껐다 켜도 유지됩니다)
    @AppStorage("limitMode") var limitModeRaw: String = LimitMode.auto.rawValue
    @AppStorage("manualSessionLimitM") var manualSessionLimitM: Double = 50
    @AppStorage("manualWeeklyLimitM") var manualWeeklyLimitM: Double = 300
    @AppStorage("manualSonnetWeeklyLimitM") var manualSonnetWeeklyLimitM: Double = 300
    @AppStorage("weeklyAnchorEnabled") var weeklyAnchorEnabled: Bool = true   // 기본: 앵커 켬
    @AppStorage("weeklyAnchorWeekday") var weeklyAnchorWeekday: Int = 2      // 월요일
    @AppStorage("weeklyAnchorMinutes") var weeklyAnchorMinutes: Int = 600    // 오전 10:00
    @AppStorage("notificationsEnabled") var notificationsEnabled: Bool = true
    @AppStorage("notifyThresholdLow") var notifyThresholdLow: Double = 70    // 1차 임계값(%)
    @AppStorage("notifyThresholdHigh") var notifyThresholdHigh: Double = 90  // 2차 임계값(%)

    var limitMode: LimitMode {
        get { LimitMode(rawValue: limitModeRaw) ?? .auto }
        set { limitModeRaw = newValue.rawValue }
    }

    private var timer: Timer?

    init() {
        // 임계값 알림을 위해 macOS 알림 권한을 요청합니다. (한 번 허용하면 유지)
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        refresh()
        // 1분마다 자동 갱신 (메뉴 막대의 퍼센트도 함께 갱신됩니다)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    /// 현재 설정으로 엔진을 한 번 돌립니다.
    /// 이전 스캔이 끝나기 전에는 다시 시작하지 않습니다 (동시 실행 충돌 방지).
    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let config = EngineConfig(
            limitMode: limitMode,
            manualSessionLimitM: manualSessionLimitM,
            manualWeeklyLimitM: manualWeeklyLimitM,
            manualSonnetWeeklyLimitM: manualSonnetWeeklyLimitM,
            weeklyAnchorEnabled: weeklyAnchorEnabled,
            weeklyAnchorWeekday: weeklyAnchorWeekday,
            weeklyAnchorMinutes: weeklyAnchorMinutes)

        Task.detached(priority: .utility) {
            let result = UsageEngine.compute(config: config)
            await MainActor.run {
                self.session = result.session
                self.weekAll = result.weekAll
                self.weekSonnet = result.weekSonnet
                self.statusMessage = result.error
                self.updatedAt = Date()
                self.isLoading = false
                self.checkThresholds()
            }
        }
    }

    /// 메뉴 막대에 보여줄 짧은 글자 (현재 세션 퍼센트)
    var menuBarText: String {
        guard let s = session else { return "–" }
        guard s.isActive else { return "휴식" }
        return "\(Int(s.percent.rounded()))%"
    }

    /// 메뉴 막대 글자 색: 70% 주황 / 90% 빨강, 그 외는 기본색(nil).
    /// 카드의 임계색 전환(barColor)과 같은 신호를 메뉴 막대에도 줍니다.
    var menuBarTint: Color? {
        guard let s = session, s.isActive else { return nil }
        if s.percent >= 90 { return .red }
        if s.percent >= 70 { return .orange }
        return nil
    }

    // MARK: 임계값 알림 (70% / 90%)

    /// 각 창의 사용률이 임계값을 넘으면 macOS 알림을 보냅니다.
    /// 같은 구간(같은 초기화 시각)에서는 임계값마다 한 번만 알립니다.
    private func checkThresholds() {
        guard notificationsEnabled else { return }
        if let s = session, s.isActive {
            notifyIfNeeded(s, name: "현재 세션", idPrefix: "session")
        }
        if let w = weekAll { notifyIfNeeded(w, name: "이번 주 (전체)", idPrefix: "weekAll") }
        if let w = weekSonnet { notifyIfNeeded(w, name: "이번 주 (Sonnet)", idPrefix: "weekSonnet") }
    }

    private func notifyIfNeeded(_ window: WindowEstimate, name: String, idPrefix: String) {
        let percent = window.percent
        // 구간을 구별하는 도장: 초기화 시각이 있으면 그것, 없으면(이동 창) 오늘 날짜.
        // 이 도장 덕분에 같은 구간에서 알림이 반복되지 않습니다.
        let stamp = window.resetsAt ?? Calendar.current.startOfDay(for: Date())
        // 사용자가 설정한 두 임계값(높은 값 먼저)을 검사합니다.
        let thresholds = [notifyThresholdHigh, notifyThresholdLow].sorted(by: >)
        for threshold in thresholds where percent >= threshold {
            let key = "notified.\(idPrefix).\(Int(stamp.timeIntervalSince1970)).\(Int(threshold))"
            if !UserDefaults.standard.bool(forKey: key) {
                UserDefaults.standard.set(true, forKey: key)
                sendNotification(
                    title: "\(name) 사용량 \(Int(threshold))% 도달 (추정)",
                    body: "현재 약 \(Int(percent.rounded()))%를 사용했습니다. 한도 관리에 참고하세요.")
            }
            break   // 가장 높은 임계값 하나만 알립니다.
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// ── 화면 표시용 포맷 도우미

/// 토큰 수를 "1.2M", "850K" 처럼 줄여 보여줍니다.
func fmtShortTokens(_ n: Int) -> String {
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
    case 1_000...:     return String(format: "%.0fK", Double(n) / 1_000)
    default:           return "\(n)"
    }
}

/// 초기화 시각: 오늘이면 "오후 6:50", 다른 날이면 "6월 15일 오전 10:00"
func fmtReset(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ko_KR")
    f.dateFormat = Calendar.current.isDateInToday(date) ? "a h:mm" : "M월 d일 a h:mm"
    return f.string(from: date)
}

/// 어떤 시각까지 남은 시간을 "2시간 13분", "4일 5시간" 형태로 보여줍니다.
func fmtRemainingUntil(_ date: Date) -> String {
    let total = max(0, Int(date.timeIntervalSinceNow))
    let d = total / 86400
    let h = (total % 86400) / 3600
    let m = (total % 3600) / 60
    if d > 0 { return h > 0 ? "\(d)일 \(h)시간" : "\(d)일" }
    if h > 0 { return "\(h)시간 \(m)분" }
    return "\(m)분"
}
