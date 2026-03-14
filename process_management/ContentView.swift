import SwiftUI

struct ContentView: View {
    @StateObject private var monitor = ProcessMonitor()

    private let windowSwitcher = WindowSwitcher()

    var body: some View {
        CanvasWorkspaceView(
            monitor: monitor,
            windowSwitcher: windowSwitcher
        )
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(.dark)
    }
}
