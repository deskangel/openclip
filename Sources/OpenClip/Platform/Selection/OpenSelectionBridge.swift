// OpenSelectionBridge.swift
// OpenClip
//
// Bridges OpenSelection to OpenClip's internal Core domain types, logging pipeline,
// and backward-compatibility interfaces.
import AppKit
import Foundation
import Core
@_exported import OpenSelection

// Disambiguate types shared with Core in favor of Core domain types within OpenClip.
public typealias AppIdentity = Core.AppIdentity
public typealias SelectionGatePolicy = Core.SelectionGatePolicy
public typealias CursorClass = Core.CursorClass
public typealias TextResult = Core.TextResult
public typealias LogLevel = Core.LogLevel

extension SelectionRetrievalCoordinator {
    /// Convenience initializer preserving compatibility with OpenClip's TextResult-based copy captures.
    public init(
        inspect: @escaping TargetProvider = { trace in AXElementInspector.inspect(trace: trace) },
        copyCapture: (@Sendable (CopyTrigger) async -> Core.TextResult?)?,
        menuPress: @escaping MenuPress = SelectionRetrievalCoordinator.pressEditCopyMenu,
        scriptRunner: @escaping ScriptRunner = SelectionRetrievalCoordinator.defaultScriptRunner
    ) {
        let mappedCapture: CopyCapture? = copyCapture.map { cc in
            { @Sendable (request: CopyRequest) in
                if let res = await cc(request.trigger) {
                    return OpenSelection.SelectionResult(
                        text: res.text,
                        bounds: res.bounds,
                        html: res.html,
                        rtf: res.rtf,
                        strategy: .keyboardCopy
                    )
                }
                return nil
            }
        }
        self.init(
            configuration: .default,
            inspect: inspect,
            copyCapture: mappedCapture,
            menuPress: menuPress,
            scriptRunner: scriptRunner
        )
    }

    /// Convenience initializer accepting parameterless SimpleTargetProvider.
    public init(
        inspect: @escaping SimpleTargetProvider,
        copyCapture: (@Sendable (CopyTrigger) async -> Core.TextResult?)?,
        menuPress: @escaping MenuPress = SelectionRetrievalCoordinator.pressEditCopyMenu,
        scriptRunner: @escaping ScriptRunner = SelectionRetrievalCoordinator.defaultScriptRunner
    ) {
        self.init(
            inspect: { _ in inspect() },
            copyCapture: copyCapture,
            menuPress: menuPress,
            scriptRunner: scriptRunner
        )
    }

    /// Reads selection details using OpenClip's Core.AppIdentity and Core.AppPolicyContext.
    public func retrieveDetails(
        for app: Core.AppIdentity,
        policy: Core.AppPolicyContext,
        cursor: Core.CursorClass,
        isSelectAll: Bool = false,
        allowCopyFallback: Bool = true,
        requireCopyEvidence: Bool = true
    ) async -> (result: Core.TextResult?, isEditable: Bool) {
        let openSelectionApp = OpenSelection.AppIdentity(bundleIdentifier: app.bundleIdentifier, localizedName: app.localizedName)
        let openSelectionPolicy = OpenSelection.SelectionPolicy(
            disabled: policy.disabled,
            hotkeyOnly: policy.hotkeyOnly,
            denyPaste: policy.denyPaste,
            useMenuCopy: policy.useMenuCopy,
            retrievalMode: OpenSelection.SelectionStrategy(rawValue: policy.retrievalMode.rawValue) ?? .axTextControl,
            gate: OpenSelection.SelectionGatePolicy(
                skipRoles: policy.gate.skipRoles,
                allowedCursors: Set(policy.gate.allowedCursors.compactMap { OpenSelection.CursorClass(rawValue: $0.rawValue) })
            )
        )
        let openSelectionCursor = OpenSelection.CursorClass(rawValue: cursor.rawValue) ?? .unknown

        let (result, isEditable) = await self.retrieveDetails(
            for: openSelectionApp,
            policy: openSelectionPolicy,
            cursor: openSelectionCursor,
            isSelectAll: isSelectAll,
            allowCopyFallback: allowCopyFallback,
            requireCopyEvidence: requireCopyEvidence
        )

        // `formattedText` performs WebKit-backed HTML import, which is main-actor isolated.
        let textResult: Core.TextResult?
        if let result {
            textResult = await MainActor.run {
                Core.TextResult(
                    text: result.formattedText,
                    bounds: result.bounds,
                    html: result.html,
                    rtf: result.rtf,
                    flavors: result.flavors.map { Core.RichPasteboardFlavor($0) }
                )
            }
        } else {
            textResult = nil
        }
        return (textResult, isEditable)
    }


    /// Reads selection using OpenClip's Core.AppIdentity and Core.AppPolicyContext.
    public func retrieve(
        for app: Core.AppIdentity,
        policy: Core.AppPolicyContext,
        cursor: Core.CursorClass,
        isSelectAll: Bool = false,
        allowCopyFallback: Bool = true,
        requireCopyEvidence: Bool = true
    ) async -> Core.TextResult? {
        await retrieveDetails(
            for: app,
            policy: policy,
            cursor: cursor,
            isSelectAll: isSelectAll,
            allowCopyFallback: allowCopyFallback,
            requireCopyEvidence: requireCopyEvidence
        ).result
    }
}

extension Core.CursorClass {
    public var asOpenSelection: OpenSelection.CursorClass {
        OpenSelection.CursorClass(rawValue: self.rawValue) ?? .unknown
    }
}

extension OpenSelection.CursorClass {
    public var asCore: Core.CursorClass {
        Core.CursorClass(rawValue: self.rawValue) ?? .unknown
    }
}

extension Core.RichPasteboardFlavor {
    public init(_ flavor: PasteboardFlavor) {
        self.init(type: flavor.type, data: flavor.data)
    }
}

extension Core.TextResult {
    @MainActor
    public init(_ result: OpenSelection.SelectionResult) {
        self.init(
            text: result.formattedText,
            bounds: result.bounds,
            html: result.html,
            rtf: result.rtf,
            flavors: result.flavors.map { Core.RichPasteboardFlavor($0) }
        )
    }
}

extension OpenSelection.SelectionResult {
    @MainActor
    public var asTextResult: Core.TextResult {
        Core.TextResult(
            text: formattedText,
            bounds: bounds,
            html: html,
            rtf: rtf,
            flavors: flavors.map { Core.RichPasteboardFlavor($0) }
        )
    }
}

extension OpenSelection {
    /// Non-destructive or clipboard-copy paste replacement for OpenClip effects.
    @MainActor
    public static func replace(
        with text: String,
        html: String? = nil,
        rtf: String? = nil,
        flavors: [PasteboardFlavor] = [],
        in app: NSRunningApplication? = nil,
        matchStyle: Bool = false,
        pasteboard: NSPasteboard = .general,
        restoreDelay: TimeInterval = 0.25,
        restorePasteboard: Bool = true,
        keyPoster: (@MainActor @Sendable (CGKeyCode, CGEventFlags) -> Void)? = nil
    ) async throws {
        let config = SelectionConfiguration(
            pasteboardDeliveryRestoreDelay: restoreDelay,
            pasteVirtualKey: Constants.vVirtualKey
        )
        let replacer = SelectionReplacer(
            configuration: config,
            pasteboard: pasteboard,
            directAXReplacer: { _, _ in false },
            keyPoster: keyPoster ?? { KeyboardEventPoster.postKey(keyCode: $0, flags: $1) }
        )
        try await replacer.replace(
            with: text,
            html: html,
            rtf: rtf,
            flavors: flavors,
            in: app,
            matchStyle: matchStyle,
            restorePasteboard: restorePasteboard
        )
    }
}

/// Diagnostics sink bridging OpenSelection structured events and cascade reports to OpenClip's logging pipeline.
public struct OpenClipDiagnosticsSink: OpenSelectionDiagnosticsSink {
    public let minimumLevel: OpenSelection.LogLevel

    public init(minimumLevel: OpenSelection.LogLevel = .debug) {
        self.minimumLevel = minimumLevel
    }

    public func record(_ event: DiagnosticEvent) {
        let coreLevel: Core.LogLevel
        switch event.level {
        case .trace, .debug:
            coreLevel = .debug
        case .info:
            coreLevel = .info
        case .warning:
            coreLevel = .warning
        case .error:
            coreLevel = .error
        case .fault:
            coreLevel = .fault
        }

        let formattedFields = event.fields.map { "\($0.key)=\(Self.format($0.value))" }.sorted().joined(separator: " ")
        let line = formattedFields.isEmpty
            ? "[\(event.traceID)] [\(event.category.rawValue)] \(event.message)"
            : "[\(event.traceID)] [\(event.category.rawValue)] \(event.message) [\(formattedFields)]"

        Log.selection.log(level: coreLevel, Core.LogMessage(stringValue: line))
    }

    public func finish(_ report: CascadeReport) {
        let isSuccess: Bool
        switch report.outcome {
        case .selection:
            isSuccess = true
        case .none, .cancelled:
            isSuccess = false
        }

        let level: Core.LogLevel = isSuccess ? .info : .warning
        let outcomeDesc: String
        switch report.outcome {
        case .selection(let strategy, let presence):
            outcomeDesc = "selection(\(strategy.rawValue), \(presence.rawValue))"
        case .none:
            outcomeDesc = "none"
        case .cancelled:
            outcomeDesc = "cancelled"
        }

        let bundleID = report.target?.bundleID ?? "unknown"
        let msg = "[CascadeReport] [\(report.traceID)] bundle=\(bundleID) outcome=\(outcomeDesc) total=\(report.totalMicros)µs attempts=\(report.attempts.count)"
        Log.selection.log(level: level, Core.LogMessage(stringValue: msg))
    }

    private static func format(_ value: OpenSelection.FieldValue) -> String {
        switch value {
        case .int(let v):
            return "\(v)"
        case .bool(let v):
            return v ? "true" : "false"
        case .micros(let v):
            return "\(v)µs"
        case .presence(let v):
            return v.rawValue
        case .ax(let v):
            return v.rawValue
        case .token(let v):
            return v
        }
    }
}


