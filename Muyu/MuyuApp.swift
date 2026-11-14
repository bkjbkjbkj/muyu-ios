import SwiftUI

@main
struct MuyuApp: App {
    @StateObject private var store = ChatStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ChatView()
                .environmentObject(store)
                .tint(Theme.accent)
                .onChange(of: phase) { _, value in
                    if value == .background { store.stop() }
                }
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.10, green: 0.43, blue: 0.35)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let subtle = Color(uiColor: .secondarySystemGroupedBackground)
}
