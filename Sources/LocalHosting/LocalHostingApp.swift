import SwiftUI

@main
struct LocalHostingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Local Hosting", id: "main") {
            ContentView()
                .environmentObject(appDelegate.state)
                .environmentObject(appDelegate.state.resources)
                .defaultAppStorage(Paths.preferences)
        }
        .defaultSize(width: 980, height: 660)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .windowBackgroundDragBehavior(.enabled)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var isTerminating = false

    /// Quitting stops the web servers and database servers and removes the /etc/hosts entries,
    /// so every domain points back at the real internet.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }
        isTerminating = true
        Task {
            await state.stopEverything()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
