import AppKit
import ServiceKit
import SwiftUI

@main
struct DevServicesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Not `@State`: that attribute is macro-backed in this SDK and its macro plugin ships only
    // with Xcode, which this project deliberately does not require. A shared root model works
    // just as well for app-level state and keeps the build Command-Line-Tools-only.
    private var model: AppModel { .shared }

    var body: some Scene {
        // A single window, not a WindowGroup: ⌘N spawning ten copies of a service manager
        // would be nothing but confusing.
        Window("Dev Services", id: MainWindowPresenter.windowID) {
            MainWindowView()
                .environment(model)
                .environment(model.postgres)
                .environment(model.vault)
                .environment(model.kafka)
                .frame(minWidth: 940, minHeight: 580)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Refresh") { Task { await model.refreshAll() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .environment(model.postgres)
                .environment(model.vault)
                .environment(model.kafka)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Manages the hybrid Dock behaviour.
///
/// The app is an `LSUIElement`, so it starts with no Dock icon and no app-switcher entry. But a
/// SwiftUI `Window` scene opens its window at launch, and an app showing a real window with no
/// Dock icon is just confusing — so the activation policy *follows window visibility* rather than
/// being toggled by whoever happened to open the window:
///
/// - a visible main window  -> `.regular`, which also gives the app a real menu bar (without one
///   there is no Edit menu, and therefore no ⌘C/⌘V/⌘Z in the SQL editor)
/// - no visible main window -> `.accessory`, menu bar item only
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainWindowPresenter.shared.startTrackingWindows()
    }

    /// Clicking the Dock icon with no window open should bring the window back, not nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindowPresenter.shared.showExistingWindow() }
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

    private var observers: [NSObjectProtocol] = []

    /// Keep the activation policy in step with whether a real window is on screen.
    func startTrackingWindows() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in MainWindowPresenter.shared.syncActivationPolicy() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
            let closing = notification.object as? NSWindow
            Task { @MainActor in
                // willClose fires before the window leaves NSApp.windows, so discount it here.
                MainWindowPresenter.shared.syncActivationPolicy(ignoring: closing)
            }
        })
        syncActivationPolicy()
    }

    /// `.regular` while a real window is visible, `.accessory` otherwise.
    func syncActivationPolicy(ignoring excluded: NSWindow? = nil) {
        let hasVisibleWindow = NSApp.windows.contains { window in
            window !== excluded && window.isVisible && Self.isMainWindow(window)
        }
        let desired: NSApplication.ActivationPolicy = hasVisibleWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
    }

    /// Bring the main window forward, promoting out of accessory mode first so it does not
    /// open behind other apps.
    func showExistingWindow() {
        syncActivationPolicy()
        if let window = NSApp.windows.first(where: Self.isMainWindow) {
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
        }
        activate()
    }

    /// Activate on the next runloop turn, so an activation-policy change has settled first.
    func activate() {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// The status-bar item is an NSWindow too; only real windows should drive the Dock icon.
    private static func isMainWindow(_ window: NSWindow) -> Bool {
        window.canBecomeMain && !(window is NSPanel)
    }
}
