import XCTest
import KeyboardShortcuts
@testable import Core
@testable import OpenClip

@MainActor
final class StatusBarControllerTests: XCTestCase {
    private var tempRulesURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { TestIsolation.reset() }
        tempRulesURL = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString).json")
    }

    override func tearDown() async throws {
        await MainActor.run { TestIsolation.reset() }
        if let tempRulesURL {
            try? FileManager.default.removeItem(at: tempRulesURL)
        }
        try await super.tearDown()
    }

    func testStartsWithoutStatusItemWhenPreferenceIsDisabled() {
        let store = MemorySettingsStore()
        store.set(.showMenuBarIcon, value: false)
        let notificationCenter = NotificationCenter()
        let controller = StatusBarController(
            settingsStore: store,
            notificationCenter: notificationCenter,
            rulesSaveURL: tempRulesURL
        )

        XCTAssertFalse(controller.isMenuBarIconVisible)
    }

    func testCaptureTextMenuItemShowsConfiguredShortcutAndIsGroupedAboveSettings() {
        let controller = StatusBarController(
            settingsStore: MemorySettingsStore(),
            notificationCenter: NotificationCenter(),
            rulesSaveURL: tempRulesURL
        )
        guard let captureItem = controller.captureTextMenuItem,
              let settingsItem = controller.settingsMenuItem,
              let actionsItem = controller.actionsMenuItem,
              let items = controller.rootMenu?.items else {
            return XCTFail("Expected the status menu navigation items")
        }

        XCTAssertEqual(captureItem.title, "Capture Text")
        XCTAssertLessThan(items.firstIndex(of: captureItem)!, items.firstIndex(of: actionsItem)!)
        XCTAssertLessThan(items.firstIndex(of: actionsItem)!, items.firstIndex(of: settingsItem)!)

        let savedShortcut = KeyboardShortcuts.getShortcut(for: .captureText)
        defer { KeyboardShortcuts.setShortcut(savedShortcut, for: .captureText) }

        KeyboardShortcuts.setShortcut(.init(.x, modifiers: [.command, .option]), for: .captureText)
        XCTAssertEqual(captureItem.keyEquivalent, "x")
        XCTAssertEqual(captureItem.keyEquivalentModifierMask, [.command, .option])

        KeyboardShortcuts.setShortcut(nil, for: .captureText)
        XCTAssertEqual(captureItem.keyEquivalent, "")
    }

    func testVisibilityNotificationRemovesAndRecreatesStatusItem() {
        let store = MemorySettingsStore()
        let notificationCenter = NotificationCenter()
        let controller = StatusBarController(
            settingsStore: store,
            notificationCenter: notificationCenter,
            rulesSaveURL: tempRulesURL
        )

        XCTAssertTrue(controller.isMenuBarIconVisible)

        store.set(.showMenuBarIcon, value: false)
        notificationCenter.post(name: .openClipMenuBarVisibilityChanged, object: false)
        XCTAssertFalse(controller.isMenuBarIconVisible)

        store.set(.showMenuBarIcon, value: true)
        notificationCenter.post(name: .openClipMenuBarVisibilityChanged, object: true)
        XCTAssertTrue(controller.isMenuBarIconVisible)

        store.set(.showMenuBarIcon, value: false)
        notificationCenter.post(name: .openClipMenuBarVisibilityChanged, object: false)
    }

    func testPauseForSetsTimestampAndUpdatesResumeItem() {
        let store = MemorySettingsStore()
        let notificationCenter = NotificationCenter()
        let controller = StatusBarController(
            settingsStore: store,
            notificationCenter: notificationCenter,
            rulesSaveURL: tempRulesURL
        )

        XCTAssertEqual(store.get(.pauseUntilTimestamp), 0.0)
        controller.updateRootMenuDynamicItems()
        XCTAssertEqual(controller.resumeItem?.isHidden, true)

        // Pause for 30 minutes
        controller.pause30Minutes()
        let timestamp = store.get(.pauseUntilTimestamp)
        XCTAssertGreaterThan(timestamp, Date().timeIntervalSince1970 + 1700)

        controller.updateRootMenuDynamicItems()
        XCTAssertEqual(controller.resumeItem?.isHidden, false)
        XCTAssertTrue(controller.resumeItem?.title.contains("Resume OpenClip") == true)
    }

    func testPauseTimerResetsTimestampWhenFired() async throws {
        let store = MemorySettingsStore()
        let notificationCenter = NotificationCenter()
        let controller = StatusBarController(
            settingsStore: store,
            notificationCenter: notificationCenter,
            rulesSaveURL: tempRulesURL
        )

        controller.pauseFor(seconds: 0.1)
        XCTAssertGreaterThan(store.get(.pauseUntilTimestamp), 0.0)

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(store.get(.pauseUntilTimestamp), 0.0)
    }

    func testResumeFromPauseClearsTimestampAndHidesResumeItem() {
        let store = MemorySettingsStore()
        let notificationCenter = NotificationCenter()
        let controller = StatusBarController(
            settingsStore: store,
            notificationCenter: notificationCenter,
            rulesSaveURL: tempRulesURL
        )

        // Pre-set a future pause timestamp
        store.set(.pauseUntilTimestamp, value: Date().timeIntervalSince1970 + 1800)
        controller.updateRootMenuDynamicItems()
        XCTAssertEqual(controller.resumeItem?.isHidden, false)

        controller.resumeFromPause()
        XCTAssertEqual(store.get(.pauseUntilTimestamp), 0.0)

        controller.updateRootMenuDynamicItems()
        XCTAssertEqual(controller.resumeItem?.isHidden, true)
    }

    func testToggleCurrentAppPauseAddsAndRemovesDisabledRule() {
        let store = MemorySettingsStore()
        let notificationCenter = NotificationCenter()
        let controller = StatusBarController(
            settingsStore: store,
            notificationCenter: notificationCenter,
            rulesSaveURL: tempRulesURL
        )

        let mockSafari = MockStatusBarApp(bundleID: "com.apple.Safari", localizedName: "Safari")
        controller.currentTargetApp = mockSafari

        // Initially Safari is not disabled
        controller.updateRootMenuDynamicItems()
        XCTAssertEqual(controller.pauseAppItem?.isHidden, false)
        XCTAssertEqual(controller.pauseAppItem?.state, .off)
        XCTAssertEqual(controller.pauseAppItem?.title, "Pause in Safari")
        XCTAssertNil(controller.pauseAppItem?.image)

        // Toggle pause for Safari
        controller.toggleCurrentAppPause()
        let policyAfterPause = RuleEngine.shared.resolvePolicies(for: "com.apple.Safari")
        XCTAssertTrue(policyAfterPause.disabled, "Safari should now be disabled")
        XCTAssertEqual(controller.pauseAppItem?.state, .on)
        XCTAssertEqual(controller.pauseAppItem?.title, "Paused in Safari")
        XCTAssertFalse(controller.pauseAppItem?.title.contains("Click to Resume") == true)
        XCTAssertNil(controller.pauseAppItem?.image)

        // Toggle resume for Safari
        controller.toggleCurrentAppPause()
        let policyAfterResume = RuleEngine.shared.resolvePolicies(for: "com.apple.Safari")
        XCTAssertFalse(policyAfterResume.disabled, "Safari should no longer be disabled")
        XCTAssertEqual(controller.pauseAppItem?.state, .off)
        XCTAssertEqual(controller.pauseAppItem?.title, "Pause in Safari")
        XCTAssertNil(controller.pauseAppItem?.image)
    }

    func testToggleCurrentAppPausePreservesMultiAppRule() {
        let store = MemorySettingsStore()
        let notificationCenter = NotificationCenter()
        let controller = StatusBarController(
            settingsStore: store,
            notificationCenter: notificationCenter,
            rulesSaveURL: tempRulesURL
        )

        // Seed multi-app disabled rule
        let multiAppRule = AppRule(bundleIdentifiers: ["com.apple.Safari", "com.google.Chrome"], disabled: true)
        RuleEngine.shared.addOrUpdateRule(multiAppRule, saveURL: tempRulesURL)

        let mockSafari = MockStatusBarApp(bundleID: "com.apple.Safari", localizedName: "Safari")
        controller.currentTargetApp = mockSafari

        // Unpause Safari
        controller.toggleCurrentAppPause()

        // Safari should now be enabled, but Chrome must remain disabled
        XCTAssertFalse(RuleEngine.shared.resolvePolicies(for: "com.apple.Safari").disabled)
        XCTAssertTrue(RuleEngine.shared.resolvePolicies(for: "com.google.Chrome").disabled)
    }

    func testAppearOnSelectionMenuItemTogglesState() {
        let store = MemorySettingsStore()
        store.set(.isAppEnabled, value: true)
        let controller = StatusBarController(
            settingsStore: store,
            notificationCenter: NotificationCenter(),
            rulesSaveURL: tempRulesURL
        )
        guard let toggleItem = controller.toggleEnabledItem else {
            return XCTFail("Expected toggleEnabledItem to be present")
        }

        XCTAssertEqual(toggleItem.title, "Appear on Selection")
        XCTAssertEqual(toggleItem.state, .on)

        store.set(.isAppEnabled, value: false)
        controller.updateStatusItem(isEnabled: false)
        XCTAssertEqual(toggleItem.state, .off)
    }

    func testAppearOnSelectionSubmenuItemsAndSelection() {
        let store = MemorySettingsStore()
        store.set(.isAppEnabled, value: true)
        store.set(.selectionModifier, value: SelectionModifier.none.rawValue)

        let controller = StatusBarController(
            settingsStore: store,
            notificationCenter: NotificationCenter(),
            rulesSaveURL: tempRulesURL
        )

        XCTAssertNotNil(controller.appearOnSelectionSubmenu)
        XCTAssertEqual(controller.toggleEnabledItem?.submenu, controller.appearOnSelectionSubmenu)
        XCTAssertEqual(controller.appearAlwaysItem?.state, .on)
        XCTAssertEqual(controller.appearOptionItem?.state, .off)
        XCTAssertEqual(controller.appearOffItem?.state, .off)
        XCTAssertEqual(controller.toggleEnabledItem?.state, .on)

        // Select Option mode
        guard let optionItem = controller.appearOptionItem,
              let action = optionItem.action else {
            return XCTFail("Expected appearOptionItem with action")
        }
        controller.perform(action, with: optionItem)
        XCTAssertEqual(store.get(.selectionModifier), SelectionModifier.option.rawValue)
        XCTAssertTrue(store.get(.isAppEnabled))
        XCTAssertEqual(controller.appearOptionItem?.state, .on)
        XCTAssertEqual(controller.appearAlwaysItem?.state, .off)
        XCTAssertEqual(controller.appearOffItem?.state, .off)
        XCTAssertEqual(controller.toggleEnabledItem?.state, .on)

        // Select Off mode
        guard let offItem = controller.appearOffItem,
              let offAction = offItem.action else {
            return XCTFail("Expected appearOffItem with action")
        }
        controller.perform(offAction, with: offItem)
        XCTAssertFalse(store.get(.isAppEnabled))
        XCTAssertEqual(controller.appearOffItem?.state, .on)
        XCTAssertEqual(controller.appearOptionItem?.state, .off)
        XCTAssertEqual(controller.appearAlwaysItem?.state, .off)
        XCTAssertEqual(controller.toggleEnabledItem?.state, .off)
    }

    func testPauseAppItemIsNestedInsidePauseSubmenu() {
        let store = MemorySettingsStore()
        let controller = StatusBarController(
            settingsStore: store,
            notificationCenter: NotificationCenter(),
            rulesSaveURL: tempRulesURL
        )

        guard let pauseSubmenu = controller.pauseSubmenu,
              let pauseAppItem = controller.pauseAppItem,
              let pauseSep = controller.pauseAppSeparatorItem else {
            return XCTFail("Expected pauseSubmenu, pauseAppItem, and separator")
        }

        XCTAssertTrue(pauseSubmenu.items.contains(pauseAppItem))
        XCTAssertTrue(pauseSubmenu.items.contains(pauseSep))
        XCTAssertLessThan(pauseSubmenu.items.firstIndex(of: pauseAppItem)!, pauseSubmenu.items.firstIndex(of: pauseSep)!)

        // With mock app:
        let mockSafari = MockStatusBarApp(bundleID: "com.apple.Safari", localizedName: "Safari")
        controller.currentTargetApp = mockSafari
        controller.updateRootMenuDynamicItems()
        XCTAssertFalse(pauseAppItem.isHidden)
        XCTAssertFalse(pauseSep.isHidden)

        // Without valid app:
        controller.currentTargetApp = MockStatusBarApp(bundleID: nil)
        controller.updateRootMenuDynamicItems()
        XCTAssertTrue(pauseAppItem.isHidden)
        XCTAssertTrue(pauseSep.isHidden)
    }
}

private final class MockStatusBarApp: NSRunningApplication {
    private let bundleID: String?
    private let locName: String?

    init(bundleID: String?, localizedName: String? = nil) {
        self.bundleID = bundleID
        self.locName = localizedName
        super.init()
    }

    override var bundleIdentifier: String? { bundleID }
    override var localizedName: String? { locName }
}
