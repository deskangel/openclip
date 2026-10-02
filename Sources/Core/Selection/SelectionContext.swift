// SelectionContext.swift
// OpenClip
//
// Represents the full context of a text selection event, including selected text, source application, screen coordinates, and app policy.
import Foundation
import CoreGraphics

public struct SelectionContext: Sendable {
    /// Generation of observed selection/focus gestures; nil for untracked contexts.
    public let selectionGeneration: UInt64?
    public let text: String
    public let sourceApp: AppIdentity
    public let cursorPosition: CGPoint
    public let mouseDownLocation: CGPoint?
    public let selectionBounds: CGRect?
    public let timestamp: Date
    public let appPolicy: AppPolicyContext
    /// True when the text came from the clipboard (shortcut triggered with no selection), not from a live selection.
    public let isClipboardFallback: Bool
    public let html: String?
    public let rtf: String?
    /// Raw pasteboard representations captured alongside the text, including app-private types.
    public let flavors: [RichPasteboardFlavor]

    public init(
        text: String,
        sourceApp: AppIdentity = AppIdentity(bundleIdentifier: "com.openclip.unknown", localizedName: "Unknown"),
        cursorPosition: CGPoint = .zero,
        mouseDownLocation: CGPoint? = nil,
        selectionBounds: CGRect? = nil,
        timestamp: Date = Date(),
        appPolicy: AppPolicyContext = .default,
        isClipboardFallback: Bool = false,
        html: String? = nil,
        rtf: String? = nil,
        flavors: [RichPasteboardFlavor] = [],
        selectionGeneration: UInt64? = nil
    ) {
        self.selectionGeneration = selectionGeneration
        self.text = text
        self.sourceApp = sourceApp
        self.cursorPosition = cursorPosition
        self.mouseDownLocation = mouseDownLocation
        self.selectionBounds = selectionBounds
        self.timestamp = timestamp
        self.appPolicy = appPolicy
        self.isClipboardFallback = isClipboardFallback
        self.html = html
        self.rtf = rtf
        self.flavors = flavors
    }

    public func with(cursorPosition: CGPoint) -> SelectionContext {
        SelectionContext(
            text: text,
            sourceApp: sourceApp,
            cursorPosition: cursorPosition,
            mouseDownLocation: mouseDownLocation,
            selectionBounds: selectionBounds,
            timestamp: timestamp,
            appPolicy: appPolicy,
            isClipboardFallback: isClipboardFallback,
            html: html,
            rtf: rtf,
            flavors: flavors,
            selectionGeneration: selectionGeneration
        )
    }
}
