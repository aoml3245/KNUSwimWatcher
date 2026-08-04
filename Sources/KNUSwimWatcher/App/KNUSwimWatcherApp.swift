import AppKit
import Darwin
import OSLog
import SwiftUI
import UserNotifications
import WatcherCore

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await AppTelemetry.shared.info("Lifecycle", "application_did_finish_launching") }
        guard !UserDefaults.standard.bool(forKey: "watcher.hasConfiguredAccount") else {
            return
        }
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@main
struct KNUSwimWatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: AppStore

    init() {
        guard SingleInstanceGuard.shared.acquire() else {
            Logger(
                subsystem: "com.woni.KNUSwimWatcher",
                category: "Lifecycle"
            ).info("duplicate_instance_blocked")
            Darwin.exit(EXIT_SUCCESS)
        }
        _store = StateObject(wrappedValue: AppStore())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(store: store)
        } label: {
            Label("KNU 수영", systemImage: store.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}
