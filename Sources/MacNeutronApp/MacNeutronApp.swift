import AppKit
import MacNeutronCore
import SwiftUI

@main
struct MacNeutronApp: App {
    @State private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)  // menu-bar app, even when run unbundled
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environment(model)
        } label: {
            Image(systemName: model.status.symbol)
        }

        Window("Set up MacNeutron", id: "setup") {
            SetupView().environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.setupComplete ? .suppressed : .presented)

        Window("Games", id: "games") {
            GamesView().environment(model)
        }

        Window("Free up space", id: "cleanup") {
            CleanupView().environment(model)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView().environment(model)
        }
    }
}

/// Brings a window to the front; a menu-bar app is never active on its own.
@MainActor func show(_ id: String, with openWindow: OpenWindowAction) {
    openWindow(id: id)
    raiseWindows()
}

/// `activate()` is only a request since macOS 14 and is refused while another app is frontmost, so the
/// window is also ordered front explicitly, on the next run-loop pass once SwiftUI has created it.
@MainActor func raiseWindows() {
    NSApplication.shared.activate()
    DispatchQueue.main.async {
        for window in NSApplication.shared.windows where window.isVisible && window.level == .normal {
            window.orderFrontRegardless()
        }
    }
}
