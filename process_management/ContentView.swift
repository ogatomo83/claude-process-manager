import SwiftUI

struct ContentView: View {
    @StateObject private var monitor = ProcessMonitor()
    @StateObject private var conversationLoader = ConversationLoader()
    @State private var selectedSession: ClaudeSession?

    private let windowSwitcher = WindowSwitcher()

    var body: some View {
        NavigationSplitView {
            SessionListView(
                sessions: monitor.sessions,
                selectedSession: $selectedSession,
                onSelect: { session in
                    selectedSession = session
                    if let path = session.jsonlPath {
                        conversationLoader.load(jsonlPath: path)
                    }
                },
                onActivate: { session in
                    windowSwitcher.activate(session: session)
                }
            )
            .frame(minWidth: 220)
        } detail: {
            ConversationView(
                session: selectedSession,
                loader: conversationLoader
            )
            .frame(minWidth: 400)
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            monitor.start()
        }
        .onDisappear {
            monitor.stop()
            conversationLoader.stop()
        }
    }
}
