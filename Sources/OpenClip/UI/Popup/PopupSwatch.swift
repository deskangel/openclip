// PopupSwatch.swift
// OpenClip
//
// The single live preview for the Appearance settings. It renders the real `PopupView` — the
// search affordance and the first actions — over a soft, abstract gradient so Glass reads as
// translucent and Classic as an opaque card. It reads the same theme, color mode and scale the
// live popup reads, so it always shows the combination the controls above resolve to. There is
// deliberately only one preview in the section; the controls below are compact segmented pickers.

import SwiftUI
import AppKit
import ImageIO
import Core

@MainActor
struct PopupSwatch: View {
    /// The canonical action set the preview shows, independent of the user's own bar so the
    /// preview is about appearance, not content. Has enough actions (13) to exercise pagination
    /// across the full 2–12 Actions Per Page slider range.
    static let actions: [any Action] = [
        CalculateAction(),
        CustomAction(id: "swatch.search", title: "Search", iconName: "magnifyingglass", type: .textSnippet(template: "")),
        CopyAction(),
        CutAction(),
        PasteAction(),
        CustomAction(id: "swatch.define", title: "Define", iconName: "book.closed", type: .textSnippet(template: "")),
        CustomAction(id: "swatch.calendar", title: "Add Event", iconName: "calendar.badge.plus", type: .textSnippet(template: "")),
        CustomAction(id: "swatch.uppercase", title: "Uppercase", iconName: "textformat.size.larger", type: .textSnippet(template: "")),
        CustomAction(id: "swatch.lowercase", title: "Lowercase", iconName: "textformat.size.smaller", type: .textSnippet(template: "")),
        CustomAction(id: "swatch.share", title: "Share", iconName: "square.and.arrow.up", type: .textSnippet(template: "")),
        CustomAction(id: "swatch.translate", title: "Translate", iconName: "character.book.closed", type: .textSnippet(template: "")),
        CustomAction(id: "swatch.summarize", title: "Summarize", iconName: "doc.text.magnifyingglass", type: .textSnippet(template: "")),
        CustomAction(id: "swatch.notes", title: "Add to Notes", iconName: "note.text.badge.plus", type: .textSnippet(template: ""))
    ]

    /// A resting hover state the preview never observes, so it never reacts to — or leaks into —
    /// the real popup's shared state.
    private static let hoverState = PopupHoverState()

    /// The desktop wallpaper every appearance preview shares, decoded once and downscaled so the
    /// tab does not re-read the image on each render.
    @MainActor private static let wallpaper: NSImage? = loadWallpaper()

    /// Height of the preview stage. Comfortably taller than the bar so there is padding above and
    /// below the popup for the gradient to read.
    var height: CGFloat = 116
    /// Extra headroom above the bar, on top of the centering slack. The bar's drop shadow reads as
    /// visual weight below it, so a touch more space on top keeps the preview from looking top-heavy.
    var topInset: CGFloat = 12

    @Setting(SettingKey.popupTheme) private var storedTheme
    @Setting(SettingKey.popupThemeColor) private var storedColor
    @Environment(\.colorScheme) private var systemScheme

    private var category: PopupThemeModel.Category {
        PopupThemeModel.category(fromStored: storedTheme)
    }

    private var effectiveTheme: String {
        if category == .glass { return "glass" }
        return PopupThemeModel.classicToken(appearance: storedColor, systemIsDark: systemScheme == .dark)
    }

    private var effectiveScheme: ColorScheme {
        PopupThemeModel.effectiveScheme(appearance: storedColor, systemIsDark: systemScheme == .dark)
    }

    @StateObject private var modeStore: PopupModeStore = {
        let store = PopupModeStore()
        store.subBarAbove = true
        return store
    }()

    var body: some View {
        let context = ActionContext(selection: mockContext.selection, modifiers: [])
        // The stage owns its size. Overlay content cannot enlarge the settings pane when
        // pagination or scale increases the popup's intrinsic width.
        Color.clear
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background {
            GeometryReader { geometry in
                backdrop
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
        }
        .overlay {
            PopupPreviewLayout {
                PopupView(
                    actions: Self.actions,
                    context: context,
                    hoverState: Self.hoverState,
                    presenter: PopupPreviewPresenter(),
                    isStatic: true,
                    modeStore: modeStore
                ) { _ in }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.top, topInset)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: PopupMetrics.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PopupMetrics.cardCornerRadius, style: .continuous)
                .strokeBorder(SettingsDesignTokens.sectionCardBorder, lineWidth: 0.5)
        )
        .environment(\.colorScheme, effectiveScheme)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.15), value: effectiveTheme)
        .animation(.easeInOut(duration: 0.15), value: effectiveScheme)
    }

    /// The blurred desktop wallpaper, so the glass material has something real to blur and Classic
    /// reads as an opaque card on the desktop. The tint tracks the color mode: darker over the
    /// wallpaper in dark mode, lighter in light mode, so the popup's contrast stays honest. Falls
    /// back to an abstract gradient when no wallpaper can be read.
    @ViewBuilder
    private var backdrop: some View {
        if let image = Self.wallpaper {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 6)
                .overlay(Color.black.opacity(effectiveScheme == .dark ? 0.32 : 0.12))
        } else {
            let stops: [Color] = effectiveScheme == .dark
                ? [
                    Color(red: 0.20, green: 0.17, blue: 0.34),
                    Color(red: 0.13, green: 0.15, blue: 0.28),
                    Color(red: 0.09, green: 0.10, blue: 0.20)
                ]
                : [
                    Color(red: 0.85, green: 0.82, blue: 0.95),
                    Color(red: 0.78, green: 0.82, blue: 0.94),
                    Color(red: 0.72, green: 0.80, blue: 0.92)
                ]
            LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    /// Decodes the current desktop wallpaper into a small thumbnail. Returns nil when the screen or
    /// image cannot be resolved, which the backdrop turns into its gradient fallback.
    private static func loadWallpaper() -> NSImage? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 800
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private var mockContext: ActionContext {
        let context = SelectionContext(
            text: "OpenClip",
            sourceApp: AppIdentity(NSRunningApplication.current),
            cursorPosition: .zero,
            selectionBounds: nil,
            timestamp: Date(),
            appPolicy: .default
        )
        return ActionContext(selection: context, modifiers: [])
    }
}

/// Preview glyphs are fixed samples rather than the user's saved action customizations.
@MainActor
private struct PopupPreviewPresenter: ActionPresenting {
    func displayTitle(for action: any Action) -> String { action.title }
    func popupIcon(for action: any Action) -> ActionIcon { action.icon }
    func tableIcon(for action: any Action) -> ActionIcon { action.icon }
}

/// Keep the contextual island at the start of the stage as the main bar grows beside it.
/// Placement never changes the size proposed by the preview stage.
private struct PopupPreviewLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let popup = subviews.first else { return }
        let size = popup.sizeThatFits(.unspecified)
        popup.place(
            at: CGPoint(
                x: bounds.minX + 16,
                y: bounds.midY - size.height / 2
            ),
            anchor: .topLeading,
            proposal: ProposedViewSize(size)
        )
    }
}
