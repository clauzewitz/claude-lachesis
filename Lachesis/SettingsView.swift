import SwiftUI
import AppKit

/// 설정 화면입니다. (독립 Window로 띄움 — ContentView 참고)
///
/// 편집 모델: UI는 로컬 @State '초안'을 편집하고, **'적용'을 누를 때만**
/// @AppStorage(영속 저장소, 같은 키)에 커밋한 뒤 store.refresh()로 반영합니다.
/// 좌상단 빨간 닫기 버튼으로 닫으면 커밋하지 않으므로 변경이 '원복'되고,
/// 다음에 열 때 onAppear가 저장값을 다시 불러옵니다.
/// (UsageStore는 종전처럼 refresh 때만 값을 읽습니다 — CLAUDE.md 구조 의도 유지)
struct SettingsView: View {
    @EnvironmentObject var store: UsageStore

    // 영속 저장소 (같은 키). '적용' 때만 여기에 씁니다.
    @AppStorage("limitMode") private var sLimitMode: String = LimitMode.auto.rawValue
    @AppStorage("manualSessionLimitM") private var sManualSession: Double = 50
    @AppStorage("manualWeeklyLimitM") private var sManualWeekly: Double = 300
    @AppStorage("manualSonnetWeeklyLimitM") private var sManualSonnet: Double = 300
    @AppStorage("weeklyAnchorEnabled") private var sAnchorEnabled: Bool = true
    @AppStorage("weeklyAnchorWeekday") private var sAnchorWeekday: Int = 2     // 월요일
    @AppStorage("weeklyAnchorMinutes") private var sAnchorMinutes: Int = 600   // 오전 10:00
    @AppStorage("notificationsEnabled") private var sNotifications: Bool = true
    @AppStorage("notifyThresholdLow") private var sNotifyLow: Double = 70
    @AppStorage("notifyThresholdHigh") private var sNotifyHigh: Double = 90

    // 편집용 초안 (적용 전까지 저장소에 반영되지 않음)
    @State private var limitModeRaw = LimitMode.auto.rawValue
    @State private var manualSessionLimitM = 50.0
    @State private var manualWeeklyLimitM = 300.0
    @State private var manualSonnetWeeklyLimitM = 300.0
    @State private var weeklyAnchorEnabled = true
    @State private var weeklyAnchorWeekday = 2      // 기본: 월요일
    @State private var weeklyAnchorMinutes = 600    // 기본: 오전 10:00
    @State private var notificationsEnabled = true
    @State private var notifyThresholdLow = 70.0
    @State private var notifyThresholdHigh = 90.0

    private let weekdays = [
        (1, "일요일"), (2, "월요일"), (3, "화요일"), (4, "수요일"),
        (5, "목요일"), (6, "금요일"), (7, "토요일")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // 머리글
            HStack {
                Text("설정")
                    .font(.system(.headline, design: .monospaced))
                Spacer()
                Button("적용") {
                    commit()                    // 초안 → 저장소
                    store.refresh()             // 새 설정으로 다시 계산
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            Form {
                // ── 한도(분모) 방식
                Section {
                    Picker("한도 기준", selection: $limitModeRaw) {
                        ForEach(LimitMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    if limitModeRaw == LimitMode.auto.rawValue {
                        hint("지금까지 관찰된 최대 사용량을 100%로 봅니다. 한도에 한 번도 닿은 적이 없으면 실제보다 높게 표시될 수 있습니다.")
                    } else {
                        TextField("세션 한도 (백만 토큰)",
                                  value: $manualSessionLimitM, format: .number)
                        TextField("주간 한도 · 전체 (백만 토큰)",
                                  value: $manualWeeklyLimitM, format: .number)
                        TextField("주간 한도 · Sonnet (백만 토큰)",
                                  value: $manualSonnetWeeklyLimitM, format: .number)
                        hint("한도에 닿았을 때 /usage 퍼센트로 역산해 적으면 정확해집니다. (예: 사용 99M인데 /usage가 23%면 약 430)")
                    }
                } header: {
                    Label("한도 계산", systemImage: "gauge.medium")
                }

                // ── 주간 초기화 시각
                Section {
                    Toggle("초기화 시각 직접 설정", isOn: $weeklyAnchorEnabled)

                    if weeklyAnchorEnabled {
                        Picker("요일", selection: $weeklyAnchorWeekday) {
                            ForEach(weekdays, id: \.0) { value, name in
                                Text(name).tag(value)
                            }
                        }
                        DatePicker("시각", selection: timeBinding,
                                   displayedComponents: .hourAndMinute)
                    }

                    hint(weeklyAnchorEnabled
                         ? "매주 \(currentWeekdayName) \(currentTimeText)에 사용량이 0으로 초기화된다고 보고 계산합니다. Claude Code의 /usage 화면에서 실제 초기화 시각을 확인하세요."
                         : "기본값인 '매주 월요일 오전 10:00' 초기화 기준으로 집계합니다. 다르면 토글을 켜고 직접 지정하세요.")
                } header: {
                    Label("주간 초기화", systemImage: "calendar")
                }

                // ── 임계값 알림
                Section {
                    Toggle("임계값 도달 시 알림", isOn: $notificationsEnabled)

                    if notificationsEnabled {
                        Stepper(value: $notifyThresholdLow, in: 5...95, step: 5) {
                            Text("1차 임계값  \(Int(notifyThresholdLow))%")
                        }
                        Stepper(value: $notifyThresholdHigh, in: 10...100, step: 5) {
                            Text("2차 임계값  \(Int(notifyThresholdHigh))%")
                        }
                    }

                    hint("설정한 두 임계값에 도달하는 순간 macOS 알림을 보냅니다. 같은 구간에서는 임계값마다 한 번만 알리며, 시스템 알림 권한을 허용해야 표시됩니다. (카드·메뉴막대의 색 전환은 디자인상 70/90% 고정입니다)")
                } header: {
                    Label("알림", systemImage: "bell")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 336, height: 520)
        // 열릴 때마다 저장값을 초안으로 불러옵니다.
        // (닫기로 커밋 없이 닫혔으면 변경분은 여기서 자연스럽게 원복됩니다)
        .onAppear { load() }
    }

    // MARK: 초안 ↔ 저장소

    private func load() {
        limitModeRaw = sLimitMode
        manualSessionLimitM = sManualSession
        manualWeeklyLimitM = sManualWeekly
        manualSonnetWeeklyLimitM = sManualSonnet
        weeklyAnchorEnabled = sAnchorEnabled
        weeklyAnchorWeekday = sAnchorWeekday
        weeklyAnchorMinutes = sAnchorMinutes
        notificationsEnabled = sNotifications
        notifyThresholdLow = sNotifyLow
        notifyThresholdHigh = sNotifyHigh
    }

    private func commit() {
        sLimitMode = limitModeRaw
        sManualSession = manualSessionLimitM
        sManualWeekly = manualWeeklyLimitM
        sManualSonnet = manualSonnetWeeklyLimitM
        sAnchorEnabled = weeklyAnchorEnabled
        sAnchorWeekday = weeklyAnchorWeekday
        sAnchorMinutes = weeklyAnchorMinutes
        sNotifications = notificationsEnabled
        sNotifyLow = notifyThresholdLow
        sNotifyHigh = notifyThresholdHigh
    }

    // MARK: 작은 부품

    /// 섹션 안내 문구 (작은 회색 글씨, 여러 줄 허용)
    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 분 단위 초안값 ↔ DatePicker(Date) 변환
    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: weeklyAnchorMinutes / 60,
                    minute: weeklyAnchorMinutes % 60,
                    second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                weeklyAnchorMinutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }

    private var currentWeekdayName: String {
        weekdays.first { $0.0 == weeklyAnchorWeekday }?.1 ?? ""
    }

    private var currentTimeText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "a h:mm"
        return f.string(from: timeBinding.wrappedValue)
    }
}

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(UsageStore())
    }
}
#endif
