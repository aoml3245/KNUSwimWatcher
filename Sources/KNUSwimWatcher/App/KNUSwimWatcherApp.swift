import AppKit
import Darwin
import OSLog
import SwiftUI
import UserNotifications
import WatcherCore

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let logger = Logger(
        subsystem: "com.woni.KNUSwimWatcher",
        category: "Lifecycle"
    )
    private var applicationLaunchObserver: NSObjectProtocol?
    private var duplicateSweepTimer: Timer?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        applicationLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else {
                return
            }
            self?.terminateDuplicate(application)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateRunningDuplicates()
        duplicateSweepTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] _ in
            self?.terminateRunningDuplicates()
        }
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

    func applicationWillTerminate(_ notification: Notification) {
        duplicateSweepTimer?.invalidate()
        if let applicationLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(applicationLaunchObserver)
        }
    }

    private func terminateRunningDuplicates() {
        NSWorkspace.shared.runningApplications.forEach(terminateDuplicate)
    }

    private func terminateDuplicate(_ application: NSRunningApplication) {
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              isKNUSwimWatcher(application) else {
            return
        }

        let duplicatePID = application.processIdentifier
        let duplicatePath = application.executableURL?.path ?? "unknown"
        logger.info(
            "duplicate_instance_terminated pid=\(duplicatePID, privacy: .public) path=\(duplicatePath, privacy: .public)"
        )
        application.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if !application.isTerminated {
                application.forceTerminate()
            }
        }
    }

    private func isKNUSwimWatcher(_ application: NSRunningApplication) -> Bool {
        application.bundleIdentifier == Bundle.main.bundleIdentifier
            || application.executableURL?.lastPathComponent == "KNUSwimWatcher"
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
