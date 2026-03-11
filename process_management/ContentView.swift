import SwiftUI

struct ContentView: View {
    @StateObject private var monitor = ProcessMonitor()
    @StateObject private var conversationLoader = ConversationLoader()

    private let windowSwitcher = WindowSwitcher()

    var body: some View {
        CanvasWorkspaceView(
            monitor: monitor,
            conversationLoader: conversationLoader,
            windowSwitcher: windowSwitcher
        )
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(.dark)
    }
}
