import AppKit
import ApplicationServices
import Core
import os

/// Off-main-thread, deadline-bounded AX check for the hold gesture's clipboard fallback.
/// Screen coordinates and the source PID are captured by the monitor before the lookup starts.
internal struct SelectionEditabilityProbe: Sendable {
    typealias Lookup = @Sendable (pid_t, CGPoint, Date) -> Bool

    private let lookup: Lookup
    private let timeout: TimeInterval
    private static let queue = DispatchQueue(label: "com.openclip.ax-editability", qos: .userInitiated, attributes: .concurrent)
    private static let inFlight = OSAllocatedUnfairLock(initialState: 0)
    private static let editableTextRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]

    static let `default` = SelectionEditabilityProbe()

    init(timeout: TimeInterval = Constants.axReadTimeout, lookup: @escaping Lookup = Self.lookupEditableText) {
        self.timeout = timeout
        self.lookup = lookup
    }

    func isEditable(at axPoint: CGPoint, pid: pid_t) async -> Bool {
        guard pid > 0, !Task.isCancelled else { return false }
        let acquired = Self.inFlight.withLock { count in
            guard count < Constants.axMaxConcurrentInspects else { return false }
            count += 1
            return true
        }
        guard acquired else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        let lookup = self.lookup
        let result = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Bool) -> Void = { value in
                let won = resumed.withLock { settled in
                    guard !settled else { return false }
                    settled = true
                    return true
                }
                if won { continuation.resume(returning: value) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
            Self.queue.async {
                // Hold the permit until the actual worker exits, even if its watchdog won.
                // A slow AX process cannot accumulate an unbounded number of worker threads.
                defer { Self.inFlight.withLock { $0 -= 1 } }
                let editable = Date() < deadline && lookup(pid, axPoint, deadline)
                finish(Date() < deadline && editable)
            }
        }
        return !Task.isCancelled && result
    }

    static func isEditable(
        hitIsEditableControl: Bool,
        focusedIsEditableControl: Bool,
        focusedFrame: CGRect?,
        pressAXPoint: CGPoint,
        tolerance: CGFloat = 12
    ) -> Bool {
        if hitIsEditableControl { return true }
        guard focusedIsEditableControl, let focusedFrame else { return false }
        return focusedFrame.insetBy(dx: -tolerance, dy: -tolerance).contains(pressAXPoint)
    }

    private static func lookupEditableText(pid: pid_t, point: CGPoint, deadline: Date) -> Bool {
        if let hit = elementAt(point: point, deadline: deadline) {
            var hitPID: pid_t = 0
            if AXUIElementGetPid(hit, &hitPID) == .success, hitPID == pid,
               isOrContainsEditableTextControl(hit, deadline: deadline) {
                return true
            }
        }
        guard let focused = focusedElement(pid: pid, deadline: deadline),
              isEditableTextControl(focused, deadline: deadline) else { return false }
        return isEditable(
            hitIsEditableControl: false,
            focusedIsEditableControl: true,
            focusedFrame: frame(of: focused, deadline: deadline),
            pressAXPoint: point
        )
    }

    private static func focusedElement(pid: pid_t, deadline: Date) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        return elementAttribute(kAXFocusedUIElementAttribute, of: appElement, deadline: deadline)
    }

    private static func elementAt(point: CGPoint, deadline: Date) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        guard applyTimeout(to: systemWide, deadline: deadline) else { return nil }
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success else { return nil }
        return element
    }

    private static func isOrContainsEditableTextControl(_ start: AXUIElement, deadline: Date) -> Bool {
        var current: AXUIElement? = start
        var depth = 0
        while let element = current, depth < 6, Date() < deadline {
            if isEditableTextControl(element, deadline: deadline) { return true }
            current = elementAttribute(kAXParentAttribute, of: element, deadline: deadline)
            depth += 1
        }
        return false
    }

    /// Keep the existing role-based gate: a settable selection range alone also admits
    /// read-only selectable text and must not authorize the clipboard fallback.
    private static func isEditableTextControl(_ element: AXUIElement, deadline: Date) -> Bool {
        guard let role = attribute(kAXRoleAttribute, of: element, deadline: deadline) as? String else { return false }
        return editableTextRoles.contains(role)
    }

    private static func frame(of element: AXUIElement, deadline: Date) -> CGRect? {
        guard let value = attribute("AXFrame", of: element, deadline: deadline),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var frame = CGRect.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cgRect, &frame) else { return nil }
        return frame
    }

    private static func elementAttribute(_ name: String, of element: AXUIElement, deadline: Date) -> AXUIElement? {
        guard let value = attribute(name, of: element, deadline: deadline),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return value as! AXUIElement
    }

    private static func attribute(_ name: String, of element: AXUIElement, deadline: Date) -> CFTypeRef? {
        guard applyTimeout(to: element, deadline: deadline) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func applyTimeout(to element: AXUIElement, deadline: Date) -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        return AXUIElementSetMessagingTimeout(element, Float(remaining)) == .success
    }
}
