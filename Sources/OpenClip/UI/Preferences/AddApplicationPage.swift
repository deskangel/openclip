// AddApplicationPage.swift
// OpenClip
//
// Picking the application an App Rule applies to, as a page reached from App Rules: the running
// and installed applications in a searchable list, or a bundle identifier typed by hand.
import SwiftUI
import AppKit
import Core

@MainActor
public struct AddApplicationPage: View {
    @ObservedObject private var router = SettingsRouter.shared

    @State private var selectedTab = 0
    @State private var searchText = ""
    @State private var customBundleID = ""

    @StateObject private var scanner = InstalledAppsScanner()

    public init() {}

    private var allApps: [InstalledAppInfo] {
        var map = [String: InstalledAppInfo]()

        for app in scanner.installedApps {
            map[app.bundleIdentifier] = app
        }

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let identifier = AppIdentity(app).ruleIdentifier,
                  !identifier.hasPrefix("com.openclip."),
                  map[identifier] == nil else { continue }
            let name = app.localizedName ?? AppIdentity(app).processName ?? identifier
            map[identifier] = InstalledAppInfo(
                name: name,
                bundleIdentifier: identifier,
                path: app.bundleURL?.path ?? app.executableURL?.path ?? ""
            )
        }

        return Array(map.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filteredApps: [InstalledAppInfo] {
        if searchText.isEmpty { return allApps }
        return allApps.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText) }
    }

    private func add(_ identifier: String) {
        RuleEngine.shared.addOrUpdateRule(AppRule(bundleIdentifiers: [identifier]))
        router.pop()
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Applications").tag(0)
                Text("Custom").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if selectedTab == 1 {
                customEntry
            } else {
                applicationList
            }
        }
    }

    private var customEntry: some View {
        SettingsEditorPage {
            VStack(alignment: .leading, spacing: 14) {
                InsetGroupCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bundle Identifier")
                            .font(.subheadline)
                        TextField("e.g. com.apple.Terminal", text: $customBundleID)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { submitCustom() }
                        Text("Use process:<name> or path:<executable> to target apps without a bundle ID. Use * to match several apps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                }
            }
        } footer: {
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { router.pop() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Rule") { submitCustom() }
                    .buttonStyle(.borderedProminent)
                    .disabled(customBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func submitCustom() {
        let trimmed = customBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        add(trimmed)
    }

    private var applicationList: some View {
        VStack(spacing: 0) {
            NativeSearchField(
                text: $searchText,
                placeholder: String(localized: "Search applications...")
            )
            .frame(height: 24)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            Divider()

            Group {
                if scanner.isLoading && scanner.installedApps.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading applications...").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filteredApps) { app in
                        Button {
                            add(app.bundleIdentifier)
                        } label: {
                            HStack(spacing: 10) {
                                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                        .resizable()
                                        .frame(width: 26, height: 26)
                                } else if !app.path.isEmpty {
                                    Image(systemName: "app.dashed")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 26, height: 26)
                                } else {
                                    Image(systemName: "app.fill")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 26, height: 26)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.name)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(app.bundleIdentifier)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Add a rule for \(app.name)"))
                    }
                    .listStyle(.inset)
                    .alternatingRowBackgrounds()
                }
            }
            .task {
                if scanner.installedApps.isEmpty {
                    _ = await scanner.scanInstalledApps()
                }
            }

            Divider()

            HStack {
                Text("Choose an application to add a rule for it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { router.pop() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}
