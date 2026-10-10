// AppUpdateManager.swift
// OpenClip
//
// Wraps Sparkle's SPUStandardUpdaterController in an ObservableObject manager with @Published
// properties that the status bar menu and General preferences tab can drive. Ed25519-verified updates
// are fetched from the appcast URL in Info.plist (SUFeedURL) — no Apple Developer ID or notarization required.
import Foundation
import AppKit
import Sparkle
import Combine
@preconcurrency import UserNotifications
import Core

@MainActor
public final class AppUpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    public static let shared = AppUpdateManager()

    public static let defaultFeedURL = "https://github.com/ganeshmshetty/openclip/releases/latest/download/appcast.xml"

    public static let updateNotificationCategory = "OPENCLIP_UPDATE_CATEGORY"

    /// Sparkle's standard controller; `startingUpdater: true` enables the background schedule
    /// configured via `SUScheduledCheckInterval` in Info.plist.
    private var controller: SPUStandardUpdaterController!

    /// Set when a newer version has been detected, nil when up to date.
    @Published public private(set) var availableUpdateVersion: String?

    /// Release notes for the detected update version, extracted from appcast description.
    @Published public private(set) var availableUpdateReleaseNotes: String?

    /// Sparkle format for the embedded release notes (markdown, html, or plain-text).
    @Published public private(set) var availableUpdateReleaseNotesFormat: String?

    /// True when the update archive has been downloaded and staged to install upon app termination.
    @Published public private(set) var isUpdateStagedForQuitInstall: Bool = false

    /// KVO-backed published state so SwiftUI views can bind directly.
    @Published public private(set) var canCheckForUpdates = false

    @Published public var automaticallyChecksForUpdates: Bool {
        didSet {
            DefaultSettingsStore.shared.set(.automaticallyChecksForUpdates, value: automaticallyChecksForUpdates)
            controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            if !automaticallyChecksForUpdates && automaticallyDownloadsUpdates {
                automaticallyDownloadsUpdates = false
            }
        }
    }

    @Published public var automaticallyDownloadsUpdates: Bool {
        didSet {
            DefaultSettingsStore.shared.set(.automaticallyDownloadsUpdates, value: automaticallyDownloadsUpdates)
            controller?.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
            if automaticallyDownloadsUpdates && !automaticallyChecksForUpdates {
                automaticallyChecksForUpdates = true
            }
        }
    }

    @Published public var notifyOnUpdate: Bool {
        didSet {
            DefaultSettingsStore.shared.set(.notifyOnUpdate, value: notifyOnUpdate)
        }
    }

    /// Kept for settings persistence. Always targets the stable feed release.
    @Published public var updateChannel: UpdateChannel {
        didSet {
            guard updateChannel != oldValue else { return }
            DefaultSettingsStore.shared.set(.updateChannel, value: updateChannel.rawValue)
            controller?.updater.resetUpdateCycleAfterShortDelay()
            Log.updates.info("Update channel changed to \(self.updateChannel.rawValue, privacy: .public)")
        }
    }

    private var isInteractiveUpdatePresented = false
    private var immediateInstallationBlock: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()
    private var lastNotifiedVersion: String?

    private override init() {
        let autoCheck = DefaultSettingsStore.shared.get(.automaticallyChecksForUpdates)
        let autoDownload = DefaultSettingsStore.shared.get(.automaticallyDownloadsUpdates)
        let notify = DefaultSettingsStore.shared.get(.notifyOnUpdate)
        let channel = UpdateChannel(rawValue: DefaultSettingsStore.shared.get(.updateChannel)) ?? .stable

        self.automaticallyChecksForUpdates = autoCheck
        self.automaticallyDownloadsUpdates = autoDownload
        self.notifyOnUpdate = notify
        self.updateChannel = channel

        super.init()

        controller = SPUStandardUpdaterController(
            startingUpdater: autoCheck,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = autoCheck
        controller.updater.automaticallyDownloadsUpdates = autoDownload

        // Mirror Sparkle's KVO-observable `canCheckForUpdates` into our @Published property.
        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
            .store(in: &cancellables)

        // Perform an initial background check after a brief grace period on launch if enabled
        if autoCheck {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.automaticallyChecksForUpdates else { return }
                self.controller.updater.checkForUpdatesInBackground()
            }
        }
    }

    // MARK: - SPUUpdaterDelegate

    public func feedURLString(for updater: SPUUpdater) -> String? {
        currentFeedURL
    }

    public func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        allowedChannelNames
    }

    /// The feed URL for OpenClip releases.
    public var currentFeedURL: String {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? Self.defaultFeedURL
    }

    public var allowedChannelNames: Set<String> {
        []
    }

    /// Triggers an interactive update check (shows Sparkle's native update window or dialog).
    public func checkForUpdates() {
        guard controller.updater.canCheckForUpdates || controller.updater.sessionInProgress else { return }
        beginInteractiveUpdatePresentation()
        controller.checkForUpdates(nil)
    }

    /// Share the Settings window's activation lease so overlapping windows keep the app regular.
    func beginInteractiveUpdatePresentation() {
        guard !isInteractiveUpdatePresented else { return }
        isInteractiveUpdatePresented = true
        AppActivationPolicy.enter()
    }

    func finishInteractiveUpdatePresentation() {
        guard isInteractiveUpdatePresented else { return }
        isInteractiveUpdatePresented = false
        AppActivationPolicy.leave()
    }

    public func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        // Sparkle calls this after the driver finishes, including cancellation, no update, and errors.
        finishInteractiveUpdatePresentation()
    }

    /// Installs the update immediately and relaunches the app if ready, or triggers an update check.
    public func installUpdateNow() {
        if let block = immediateInstallationBlock {
            block()
        } else {
            checkForUpdates()
        }
    }

    /// Marks the update as staged to install automatically when OpenClip terminates.
    public func installUpdateOnQuit() {
        self.isUpdateStagedForQuitInstall = true
        Log.updates.info("Update staged for install on quit")
    }

    /// Returns the date of the last successful update check, if any.
    public var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }

    public func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString ?? item.versionString
        Log.updates.info("Sparkle found valid update: v\(version, privacy: .public)")
        self.availableUpdateVersion = version
        self.availableUpdateReleaseNotes = item.itemDescription
        self.availableUpdateReleaseNotesFormat = item.itemDescriptionFormat
        if notifyOnUpdate {
            self.postUpdateNotification(version: version, isReadyToInstall: false)
        }
    }

    public func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        Log.updates.info("Sparkle: no update found or up to date: \(error.localizedDescription, privacy: .public)")
        self.availableUpdateVersion = nil
        self.availableUpdateReleaseNotes = nil
        self.availableUpdateReleaseNotesFormat = nil
        self.isUpdateStagedForQuitInstall = false
        self.immediateInstallationBlock = nil
    }

    public func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Log.updates.info("Sparkle: no update found or up to date")
        self.availableUpdateVersion = nil
        self.availableUpdateReleaseNotes = nil
        self.availableUpdateReleaseNotesFormat = nil
        self.isUpdateStagedForQuitInstall = false
        self.immediateInstallationBlock = nil
    }

    public func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        self.availableUpdateVersion = nil
        self.availableUpdateReleaseNotes = nil
        self.availableUpdateReleaseNotesFormat = nil
        self.isUpdateStagedForQuitInstall = false
        self.immediateInstallationBlock = nil
    }

    public func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString ?? item.versionString
        Log.updates.info("Sparkle: update v\(version, privacy: .public) downloaded and staged for install on quit")
        self.availableUpdateVersion = version
        self.availableUpdateReleaseNotes = item.itemDescription
        self.availableUpdateReleaseNotesFormat = item.itemDescriptionFormat
        self.isUpdateStagedForQuitInstall = true
        self.immediateInstallationBlock = immediateInstallationBlock
        if notifyOnUpdate {
            self.postUpdateNotification(version: version, isReadyToInstall: true)
        }
        return false // Let Sparkle continue its normal scheduler and install automatically on quit
    }

    public func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        // Sparkle uses error code 1001 (SUNoUpdateError) when no update is found and 4001 (SUInstallationCanceledError)
        // when an update check is canceled. These are expected control flow, not system failures.
        if nsError.code == 1001 || nsError.code == 4001 {
            if nsError.code == 1001 {
                Log.updates.info("Sparkle update check completed: app is up to date")
            } else {
                Log.updates.info("Sparkle update check canceled by user")
            }
            return
        }
        Log.updates.error("Sparkle update error (\(nsError.code)): \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - User Notifications

    private func postUpdateNotification(version: String, isReadyToInstall: Bool = false) {
        guard lastNotifiedVersion != version || isReadyToInstall else { return }
        lastNotifiedVersion = version

        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            var isAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            if settings.authorizationStatus == .notDetermined {
                do {
                    isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
                } catch {
                    Log.updates.error("Failed to request notification permission for update: \(error.localizedDescription, privacy: .private)")
                }
            }
            guard isAuthorized else { return }

            let content = UNMutableNotificationContent()
            content.title = isReadyToInstall
                ? String(localized: "OpenClip Update Ready")
                : String(localized: "OpenClip Update Available")
            content.body = isReadyToInstall
                ? String(localized: "Version \(version) is ready to install on quit, or click to install now.")
                : String(localized: "Version \(version) is available. Click to install the update.")
            content.sound = .default
            content.categoryIdentifier = Self.updateNotificationCategory
            content.userInfo = ["type": "app_update", "version": version]

            let request = UNNotificationRequest(
                identifier: "com.openclip.update.available.\(version)",
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
            } catch {
                Log.updates.error("Failed to post update notification: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    // MARK: - Testing Hooks

    public func setAvailableUpdateVersionForTesting(
        _ version: String?,
        releaseNotes: String? = nil,
        releaseNotesFormat: String? = nil,
        isStagedForQuit: Bool = false
    ) {
        self.availableUpdateVersion = version
        self.availableUpdateReleaseNotes = releaseNotes
        self.availableUpdateReleaseNotesFormat = releaseNotesFormat ?? (releaseNotes == nil ? nil : "markdown")
        self.isUpdateStagedForQuitInstall = isStagedForQuit
    }
}
