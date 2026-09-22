import AppKit
import PGKit
import SwiftUI

@main
struct PostgresManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Not `@State`: that attribute is macro-backed in this SDK and its macro plugin ships only
    // with Xcode, which this project deliberately does not require. A shared root model works
    // just as well for app-level state and keeps the build Command-Line-Tools-only.
    private var model: AppModel { .shared }

    var body: some Scene {
        // A single window, not a WindowGroup: ⌘N spawning ten copies of a server manager
        // would be nothing but confusing.
        Window("Postgres Manager", id: MainWindowPresenter.windowID) {
            MainWindowView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Refresh") { Task { await model.refreshEverything() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            Image(systemName: model.status.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Manages the hybrid Dock behaviour.
///
/// The app launches as an accessory (menu bar only, no Dock icon). Opening the main window
/// promotes it to a regular app, which is what gives it a real menu bar — without that there is
/// no Edit menu, and therefore no ⌘C/⌘V/⌘Z in the SQL editor. Closing the window demotes it again.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Clicking the Dock icon with no window open should bring the window back, not nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainWindowPresenter.shared.prepareToShowWindow()
            MainWindowPresenter.shared.focusExistingWindow()
            MainWindowPresenter.shared.activate()
        }
        return true
    }

    /// The app lives in the menu bar; closing its window must not quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
final class MainWindowPresenter {
    static let shared = MainWindowPresenter()
    static let windowID = "main"

    private var observer: NSObjectProtocol?

    /// Promote to a regular app so the window gets a real menu bar. Call this *before*
    /// `openWindow(id:)` — in the other order the window opens behind other apps.
    func prepareToShowWindow() {
        NSApp.setActivationPolicy(.regular)
        observeWindowClose()
    }

    /// Activate after the policy change has settled, otherwise focus does not follow.
    func activate() {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Bring an already-open window forward, if there is one.
    @discardableResult
    func focusExistingWindow() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else {
            return false
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Drop back to menu-bar-only once the last real window goes away.
    private func observeWindowClose() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
            guard let closing = notification.object as? NSWindow, closing.canBecomeMain else { return }
            Task { @MainActor in
                // willClose fires before the window leaves NSApp.windows, so the one closing
                // is still counted here.
                let remaining = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && $0 !== closing }
                if remaining.isEmpty {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}
