// AIPage.swift
// OpenClip
//
// The AI settings page: which engine answers, and the library of prompts that appear in the AI
// Tools group — with each prompt a page of its own. Whether AI Tools is on at all is the switch in
// the toolbar, beside the back and forward arrows, the same as an installed extension's.
//
// AI settings used to hang off the gear on the "AI Tools" row of the Actions list, which opened a
// fixed 440x480 popover with its own segmented sub-tabs and a sheet on top of those for editing a
// prompt. It is a whole provider's worth of configuration, not a per-action setting, so it gets the
// same treatment as an installed extension: a row in the sidebar and a page.

import SwiftUI
import Core

@MainActor
struct AIPage: View {
    @ObservedObject private var aiManager = AIServiceManager.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    let size: CGFloat = 42
                    let radius = SettingsDesignTokens.iconTileRadius(for: size)
                    let squircle = RoundedRectangle(cornerRadius: radius, style: .continuous)

                    ZStack {
                        squircle
                            .fill(SettingsTint.neutral)
                            .shadow(color: Color.black.opacity(0.12), radius: 2, y: 1)

                        Image(systemName: SettingsPage.ai.systemImage)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .frame(width: size, height: size)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "AI Tools"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(SettingsDesignTokens.primaryText)
                            .lineLimit(1)

                        Text(String(localized: "Rewrite, summarize, translate or ask about the selected text."))
                            .font(.system(size: 12))
                            .foregroundStyle(SettingsDesignTokens.secondaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Toggle("", isOn: $aiManager.isAIEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.regular)
                }
                .padding(.vertical, 4)
            }

            AIConfigureForm(embedded: true)

            AIActionsSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// Adding a prompt, as the next page rather than a sheet over everything.
@MainActor
struct AINewPresetPage: View {
    @ObservedObject private var router = SettingsRouter.shared
    @ObservedObject private var aiManager = AIServiceManager.shared

    @State private var title: String = ""
    @State private var prompt: String = ""

    private var canAdd: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        SettingsEditorPage {
            AIPromptFields(
                title: $title,
                prompt: $prompt,
                titlePlaceholder: String(localized: "e.g. Simplify"),
                promptPlaceholder: String(localized: "e.g. Rewrite text using simple 5th-grade vocabulary")
            )
        } footer: {
            HStack(spacing: 12) {
                Spacer()

                Button("Cancel") { router.pop() }
                    .keyboardShortcut(.cancelAction)

                Button("Add Action") {
                    let preset = aiManager.addCustomPreset(title: title, prompt: prompt)
                    router.show(path: [.ai, .aiPreset(id: preset.id)])
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdd)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The two fields a prompt has, in one card.
private struct AIPromptFields: View {
    @Binding var title: String
    @Binding var prompt: String
    var titlePlaceholder: String = String(localized: "Title")
    var promptPlaceholder: String = String(localized: "Prompt instruction...")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InsetGroupCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Text("Action Title")
                            .font(.subheadline)
                        Spacer()
                        TextField(titlePlaceholder, text: $title)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()
                        .padding(.horizontal, 12)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Prompt Instruction")
                            .font(.subheadline)
                        TextField(promptPlaceholder, text: $prompt, axis: .vertical)
                            .lineLimit(4...12)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }

            Text("The selected text is appended to the instruction when the action runs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
    }
}
