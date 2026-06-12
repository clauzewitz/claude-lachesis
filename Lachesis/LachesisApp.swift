import SwiftUI

/// 앱의 시작점입니다.
/// 메뉴 막대에 게이지 아이콘과 현재 세션 퍼센트를 함께 보여 주고,
/// 누르면 사용량 창이 펼쳐집니다.
/// (독에 아이콘이 뜨지 않는 것은 빌드 설정의 LSUIElement로 처리됩니다)
@main
struct LachesisApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        // 설정은 독립된 창으로 띄웁니다.
        // MenuBarExtra(.window)의 임시 패널 위에 .sheet로 올리면,
        // 컨트롤을 클릭하는 순간 패널이 key를 잃고 팝오버째 닫혀 버립니다.
        // 별도 Window로 분리하면 클릭해도 닫히지 않습니다. (Window/openWindow는 macOS 13+)
        Window("설정", id: "settings") {
            SettingsView()
                .environmentObject(store)
        }
        .windowResizability(.contentSize)
    }
}

/// 메뉴 막대에 표시되는 작은 라벨입니다.
/// store를 관찰하고 있어서 1분마다 퍼센트가 자동으로 바뀝니다.
struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "chart.bar.yaxis")
            Text(store.menuBarText)
                .font(.system(size: 12, design: .monospaced))
        }
        // 임계값(70/90%)을 넘으면 색으로 신호. 그 외엔 기본색.
        .foregroundStyle(store.menuBarTint ?? .primary)
    }
}
