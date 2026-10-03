import AppKit
import CoreGraphics
import Core
import ScreenCaptureKit
import Vision

/// Owns the one-shot screen region capture and local Vision OCR flow.
@MainActor
final class CaptureTextController {
    private weak var popupController: PopupWindowController?
    private var panels: [RegionSelectionPanel] = []
    private var captureTask: Task<Void, Never>?
    private let cursorLease = CaptureCursorLease()
    private var requestID: UUID?
    private var sourceApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    init(popupController: PopupWindowController) {
        self.popupController = popupController
    }

    var isCapturing: Bool { requestID != nil }

    func toggleCapture(sourceApp: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        if requestID != nil {
            cancel()
            return
        }
        guard HotkeyManager.triggerAllowed(frontmost: sourceApp) else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            showFailure(String(localized: "Allow Screen Recording for OpenClip in System Settings, then reopen OpenClip."))
            return
        }
        guard !NSScreen.screens.isEmpty else {
            showFailure(String(localized: "Could not capture this screen. Check Screen Recording access in System Settings."))
            return
        }

        let id = UUID()
        requestID = id
        self.sourceApp = sourceApp
        HotkeyManager.shared.enableCaptureCancellation()
        observeSourceAppActivation(for: id)
        let screens = NSScreen.screens
        panels = screens.map { screen in
            let panel = RegionSelectionPanel(screen: screen)
            panel.onCursorRefresh = { [weak self] in self?.cursorLease.refresh() }
            panel.onCancel = { [weak self] in self?.cancel() }
            panel.onSelection = { [weak self] rect, releasePoint, mouseDownPoint, selectedScreen in
                self?.beginRecognition(rect: rect, releasePoint: releasePoint, mouseDownPoint: mouseDownPoint, screen: selectedScreen, requestID: id)
            }
            panel.makeKeyAndOrderFront(nil)
            return panel
        }
        // Cursor rectangles may not be recalculated when nonactivating panels are ordered front.
        // Hold one explicit cursor override for the whole multi-display capture session.
        cursorLease.begin()
    }

    func cancel() {
        requestID = nil
        captureTask?.cancel()
        captureTask = nil
        HotkeyManager.shared.disableCaptureCancellation()
        removeActivationObserver()
        closePanels()
    }

    private func beginRecognition(rect: CGRect, releasePoint: CGPoint, mouseDownPoint: CGPoint, screen: NSScreen, requestID id: UUID) {
        guard requestID == id else { return }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
        guard let displayID,
              let geometry = CaptureRegionGeometry.map(rect: rect, screenFrame: screen.frame, scale: screen.backingScaleFactor, displayID: displayID) else {
            cancel()
            showFailure(String(localized: "Select a larger area"))
            return
        }
        // Restore the captured display immediately. The screenshot and Vision work do not need
        // the selector panels, and ScreenCaptureKit already excludes every OpenClip window.
        CaptureTextReleaseHandoff.closeOverlayThenStartWork(closeOverlay: closePanels) { [weak self] in
            guard let self else { return }
            self.captureTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.requestID == id {
                        self.requestID = nil
                        self.captureTask = nil
                        HotkeyManager.shared.disableCaptureCancellation()
                        self.removeActivationObserver()
                        self.closePanels()
                    }
                }
                do {
                    let image = try await Self.capture(displayID: geometry.displayID, sourceRect: geometry.sourceRect, pixelSize: geometry.pixelSize)
                    try Task.checkCancellation()
                    let text = try await Self.recognize(image)
                    try Task.checkCancellation()
                    guard self.requestID == id,
                          self.isSourceAppStillActive,
                          HotkeyManager.triggerAllowed(frontmost: self.sourceApp) else { return }
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        self.showFailure(String(localized: "No text found"))
                        return
                    }
                    let identity = self.sourceApp.map(AppIdentity.init) ?? AppIdentity(bundleIdentifier: nil, localizedName: nil)
                    let anchor = CaptureTextPopupAnchor.resolve(
                        releasePoint: releasePoint,
                        mouseDownPoint: mouseDownPoint,
                        currentPointer: NSEvent.mouseLocation
                    )
                    let context = SelectionContext(
                        text: text,
                        sourceApp: identity,
                        cursorPosition: anchor.cursorPosition,
                        mouseDownLocation: anchor.mouseDownLocation,
                        selectionBounds: rect,
                        timestamp: Date(),
                        appPolicy: RuleEngine.shared.resolvePolicies(for: identity.bundleIdentifier ?? ""),
                        source: .ocr,
                        isEditable: false,
                        pasteTargetAvailable: false
                    )
                    self.popupController?.previousFrontmostApp = self.sourceApp
                    self.popupController?.show(for: context, pasteAvailable: false)
                } catch is CancellationError {
                    return
                } catch {
                    guard self.requestID == id else { return }
                    self.showFailure(String(localized: "Could not capture text. Allow Screen Recording in System Settings, then try again."))
                }
            }
        }
    }

    private func closePanels() {
        CaptureOverlayCleanup.close(
            closeOverlays: {
                self.panels.forEach { $0.close() }
                self.panels.removeAll()
            },
            // Pop only after AppKit has removed each overlay's cursor rects.
            restoreCursor: { self.cursorLease.end() }
        )
    }

    private var isSourceAppStillActive: Bool {
        guard let sourceApp else { return false }
        let frontmost = NSWorkspace.shared.frontmostApplication
        return frontmost?.processIdentifier == sourceApp.processIdentifier
            || frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private func observeSourceAppActivation(for id: UUID) {
        removeActivationObserver()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, self.requestID == id, let activatedApp else { return }
                let isOpenClip = activatedApp.bundleIdentifier == Bundle.main.bundleIdentifier
                let isSource = activatedApp.processIdentifier == self.sourceApp?.processIdentifier
                if !isOpenClip && !isSource { self.cancel() }
            }
        }
    }

    private func removeActivationObserver() {
        guard let activationObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        self.activationObserver = nil
    }

    private func showFailure(_ message: String) {
        popupController?.showToast(StatusFeedback(message: message, style: .info, symbolName: "viewfinder"), at: NSEvent.mouseLocation)
    }

    private static func capture(displayID: CGDirectDisplayID, sourceRect: CGRect, pixelSize: CGSize) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable
        }
        let excluded = content.windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int(pixelSize.width.rounded()))
        configuration.height = max(1, Int(pixelSize.height.rounded()))
        configuration.showsCursor = false
        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error { continuation.resume(throwing: error) }
                else if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: CaptureError.noImage) }
            }
        }
    }

    private static func recognize(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: image)
            try handler.perform([request])
            let observations = request.results ?? []
            let ordered = observations.sorted {
                if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.012 {
                    return $0.boundingBox.midY > $1.boundingBox.midY
                }
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
            return ordered.compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }

    private enum CaptureError: Error { case displayUnavailable, noImage }
}

@MainActor
enum CaptureTextReleaseHandoff {
    static func closeOverlayThenStartWork(closeOverlay: () -> Void, startWork: () -> Void) {
        closeOverlay()
        startWork()
    }
}

@MainActor
final class CaptureCursorLease {
    private let pushCursor: () -> Void
    private let popCursor: () -> Void
    private let setCursor: () -> Void
    private(set) var isActive = false

    init(
        pushCursor: @escaping () -> Void = { NSCursor.crosshair.push() },
        popCursor: @escaping () -> Void = { NSCursor.pop() },
        setCursor: @escaping () -> Void = { NSCursor.crosshair.set() }
    ) {
        self.pushCursor = pushCursor
        self.popCursor = popCursor
        self.setCursor = setCursor
    }

    func begin() {
        guard !isActive else { return }
        isActive = true
        pushCursor()
        setCursor()
    }

    func refresh() {
        guard isActive else { return }
        setCursor()
    }

    func end() {
        guard isActive else { return }
        isActive = false
        popCursor()
    }
}

@MainActor
enum CaptureOverlayCleanup {
    static func close(closeOverlays: () -> Void, restoreCursor: () -> Void) {
        closeOverlays()
        restoreCursor()
    }
}

struct CaptureTextPopupAnchor: Equatable {
    let cursorPosition: CGPoint
    let mouseDownLocation: CGPoint?

    static func resolve(
        releasePoint: CGPoint,
        mouseDownPoint: CGPoint,
        currentPointer: CGPoint,
        movementThreshold: CGFloat = 8
    ) -> CaptureTextPopupAnchor {
        let movedX = currentPointer.x - releasePoint.x
        let movedY = currentPointer.y - releasePoint.y
        guard hypot(movedX, movedY) > movementThreshold else {
            return CaptureTextPopupAnchor(cursorPosition: releasePoint, mouseDownLocation: mouseDownPoint)
        }
        return CaptureTextPopupAnchor(cursorPosition: currentPointer, mouseDownLocation: nil)
    }
}

struct CaptureRegionGeometry: Equatable {
    let displayID: CGDirectDisplayID
    let sourceRect: CGRect
    let pixelSize: CGSize

    static func map(rect: CGRect, screenFrame: CGRect, scale: CGFloat, displayID: CGDirectDisplayID) -> CaptureRegionGeometry? {
        let clamped = rect.standardized.intersection(screenFrame)
        guard clamped.width >= 8, clamped.height >= 8 else { return nil }
        let local = CGRect(x: clamped.minX - screenFrame.minX,
                           y: screenFrame.maxY - clamped.maxY,
                           width: clamped.width, height: clamped.height)
        let safeScale = max(1, scale)
        return CaptureRegionGeometry(
            displayID: displayID,
            sourceRect: local,
            pixelSize: CGSize(width: local.width * safeScale, height: local.height * safeScale)
        )
    }
}

@MainActor
private final class RegionSelectionPanel: NSPanel {
    private let displayScreen: NSScreen
    var onCursorRefresh: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSelection: ((CGRect, CGPoint, CGPoint, NSScreen) -> Void)?

    init(screen: NSScreen) {
        displayScreen = screen
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        acceptsMouseMovedEvents = true
        contentView = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), owner: self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    fileprivate func refreshCaptureCursor() { onCursorRefresh?() }
    fileprivate func finish(_ rect: CGRect, releasePoint: CGPoint, mouseDownPoint: CGPoint) {
        onSelection?(rect, releasePoint, mouseDownPoint, displayScreen)
    }
    fileprivate func cancelSelection() { onCancel?() }
}

@MainActor
private final class RegionSelectionView: NSView {
    weak var owner: RegionSelectionPanel?
    private var cursorTrackingArea: NSTrackingArea?
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var mouseDownScreenPoint: CGPoint?

    init(frame: CGRect, owner: RegionSelectionPanel) { self.owner = owner; super.init(frame: frame) }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        cursorTrackingArea = trackingArea
    }

    override func cursorUpdate(with event: NSEvent) {
        owner?.refreshCaptureCursor()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        owner?.refreshCaptureCursor()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        owner?.refreshCaptureCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        owner?.refreshCaptureCursor()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.32).setFill()
        bounds.fill()
        if let startPoint, let currentPoint {
            let rect = CGRect(x: min(startPoint.x, currentPoint.x), y: min(startPoint.y, currentPoint.y), width: abs(currentPoint.x - startPoint.x), height: abs(currentPoint.y - startPoint.y))
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            path.stroke()
            NSColor.white.withAlphaComponent(0.16).setFill()
            path.fill()
        } else {
            let text = String(localized: "Drag to capture text · Esc to cancel")
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        owner?.refreshCaptureCursor()
        startPoint = convert(event.locationInWindow, from: nil)
        mouseDownScreenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        currentPoint = startPoint
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        owner?.refreshCaptureCursor()
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let startPoint else { return }
        owner?.refreshCaptureCursor()
        currentPoint = convert(event.locationInWindow, from: nil)
        let local = CGRect(x: min(startPoint.x, currentPoint!.x), y: min(startPoint.y, currentPoint!.y), width: abs(startPoint.x - currentPoint!.x), height: abs(startPoint.y - currentPoint!.y))
        let screenRect = local.offsetBy(dx: owner?.frame.minX ?? 0, dy: owner?.frame.minY ?? 0)
        let releasePoint = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        owner?.finish(screenRect, releasePoint: releasePoint, mouseDownPoint: mouseDownScreenPoint ?? releasePoint)
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { owner?.cancelSelection() } else { super.keyDown(with: event) } }
}
