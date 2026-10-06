import AppKit
import XCTest
@testable import Core
@testable import OpenClip

@MainActor
private final class SpaceTestPanel: PopupPanel {
    var simulatedActiveSpace = false
    var reportedVisible = true
    var reportedKey = false
    var ordering: [String] = []
    override var isOnActiveSpace: Bool { simulatedActiveSpace }
    override var isVisible: Bool { reportedVisible }
    override var isKeyWindow: Bool { reportedKey }
    override func orderOut(_ sender: Any?) { ordering.append("out") }
    override func orderFront(_ sender: Any?) { ordering.append("front") }
}

@MainActor
final class PopupSpaceRecoveryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestIsolation.reset()
    }

    private func fixture() -> (PopupWindowController, SpaceTestPanel) {
        let controller = PopupWindowController(settingsStore: MemorySettingsStore())
        let panel = SpaceTestPanel()
        controller.panel = panel
        controller.startTestSession(for: SelectionContext(text: "private selection",
            sourceApp: AppIdentity(bundleIdentifier: "com.test.source", processIdentifier: 99999), traceID: 42))
        return (controller, panel)
    }

    func testOffSpacePopupRecreatesOnceWithoutReplacingContentOrTakingFocus() {
        let (controller, panel) = fixture()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        panel.contentView = content
        let frame = panel.frame
        let attempt = controller.presentationAttemptID
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
        let replacement = SpaceTestPanel()
        XCTAssertTrue(controller.recoverPopupSpaceIfNeeded(for: attempt, frontmostPID: 99999, makePanel: { replacement }))
        XCTAssertTrue(controller.panel === replacement)
        XCTAssertEqual(panel.ordering, ["out"])
        XCTAssertEqual(replacement.ordering, ["front"])
        XCTAssertNil(panel.contentView)
        XCTAssertTrue(replacement.contentView === content)
        XCTAssertEqual(replacement.frame, frame)
        XCTAssertFalse(replacement.canBecomeKey)
        XCTAssertTrue(replacement.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(controller.recoverPopupSpaceIfNeeded(for: attempt, frontmostPID: 99999))
        XCTAssertEqual(panel.ordering, ["out"])
        controller.hide()
    }

    func testHealthyHiddenKeyAndChangedSourcePopupsAreNotReordered() {
        let (controller, panel) = fixture()
        let attempt = controller.presentationAttemptID
        panel.simulatedActiveSpace = true
        XCTAssertFalse(controller.recoverPopupSpaceIfNeeded(for: attempt, frontmostPID: 99999))
        panel.simulatedActiveSpace = false
        panel.reportedVisible = false
        XCTAssertFalse(controller.recoverPopupSpaceIfNeeded(for: attempt, frontmostPID: 99999))
        panel.reportedVisible = true
        panel.reportedKey = true
        XCTAssertFalse(controller.recoverPopupSpaceIfNeeded(for: attempt, frontmostPID: 99999))
        panel.reportedKey = false
        XCTAssertFalse(controller.recoverPopupSpaceIfNeeded(for: attempt, frontmostPID: 88888))
        XCTAssertFalse(controller.recoverPopupSpaceIfNeeded(for: attempt, frontmostPID: nil))
        controller.modeStore.mode = .search
        XCTAssertFalse(controller.recoverPopupSpaceIfNeeded(for: attempt, frontmostPID: 99999))
        controller.modeStore.mode = .content
        XCTAssertFalse(controller.recoverPopupSpaceIfNeeded(for: attempt, frontmostPID: 99999))
        XCTAssertTrue(panel.ordering.isEmpty)
        controller.hide()
    }

    func testStaleChecksCannotRecoverReplacementOrDismissedPopup() {
        let (controller, panel) = fixture()
        let oldAttempt = controller.presentationAttemptID
        controller.startTestSession(for: SelectionContext(text: "replacement",
            sourceApp: AppIdentity(processIdentifier: 99999)))
        XCTAssertFalse(controller.recoverPopupSpaceIfNeeded(for: oldAttempt, frontmostPID: 99999))
        XCTAssertTrue(panel.ordering.isEmpty)
        let currentAttempt = controller.presentationAttemptID
        controller.hide()
        panel.ordering.removeAll()
        XCTAssertFalse(controller.recoverPopupSpaceIfNeeded(for: currentAttempt, frontmostPID: 99999))
        XCTAssertTrue(panel.ordering.isEmpty)
    }
}
