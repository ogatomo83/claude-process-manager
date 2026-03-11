import SwiftUI

@main
struct process_managementApp: App {
    init() {
        NotificationService.shared.requestPermission()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 700)
    }
}
