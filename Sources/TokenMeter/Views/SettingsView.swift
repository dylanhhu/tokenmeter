import AppKit
import SwiftUI
import TokenMeterKit

enum WindowID {
    static let settings = "settings"
}

struct SettingsView: View {
    let model: AppModel

    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section {
                ForEach(model.descriptors) { descriptor in
                    ProviderRow(model: model, descriptor: descriptor)
                }
            } header: {
                Text("Providers")
            } footer: {
                Text(
                    "Enable only the providers you use. Spend from all of them is combined into one total."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Menu Bar") {
                Picker("Show spend for", selection: windowBinding) {
                    ForEach(SpendWindow.allCases) { window in
                        Text(window.title).tag(window)
                    }
                }
                Picker("Label style", selection: styleBinding) {
                    ForEach(MenuBarStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Picker("Breakdown grouping", selection: groupingBinding) {
                    ForEach(SpendGrouping.allCases) { grouping in
                        Text(grouping.title).tag(grouping)
                    }
                }
                Picker("Breakdown measured by", selection: measureBinding) {
                    ForEach(BreakdownMeasure.allCases) { measure in
                        Text(measure.title).tag(measure)
                    }
                }
                Picker("Series shown", selection: seriesLimitBinding) {
                    ForEach([4, 5, 6, 8, 10, 12], id: \.self) { limit in
                        Text("\(limit)").tag(limit)
                    }
                }
            }

            Section {
                Picker("Refresh every", selection: intervalBinding) {
                    Text("1 minute").tag(TimeInterval(60))
                    Text("5 minutes").tag(TimeInterval(300))
                    Text("15 minutes").tag(TimeInterval(900))
                    Text("30 minutes").tag(TimeInterval(1800))
                    Text("1 hour").tag(TimeInterval(3600))
                }
                Picker("Bucket time zone", selection: timeZoneBinding) {
                    ForEach(TimeZoneMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("Open at login", isOn: launchAtLoginBinding)
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(
                    "Usage is stored in UTC and re-bucketed to the selected time zone. Day-level history can shift by one bucket."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: Self.version)
                LabeledContent("Data") {
                    Button("Reveal settings in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([SettingsStore().fileURL])
                    }
                    .controlSize(.small)
                }
                Button("Quit TokenMeter") {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 660)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            // The user may have toggled the login item in System Settings.
            let actual = LaunchAtLogin.isEnabled
            if actual != model.settings.launchAtLogin {
                model.updateSettings { $0.launchAtLogin = actual }
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    // MARK: - Bindings

    private var windowBinding: Binding<SpendWindow> {
        Binding(
            get: { model.settings.menuBarWindow },
            set: { value in model.updateSettings { $0.menuBarWindow = value } }
        )
    }

    private var styleBinding: Binding<MenuBarStyle> {
        Binding(
            get: { model.settings.menuBarStyle },
            set: { value in model.updateSettings { $0.menuBarStyle = value } }
        )
    }

    private var groupingBinding: Binding<SpendGrouping> {
        Binding(
            get: { model.settings.grouping },
            set: { value in model.updateSettings { $0.grouping = value } }
        )
    }

    private var measureBinding: Binding<BreakdownMeasure> {
        Binding(
            get: { model.settings.breakdownMeasure },
            set: { value in model.updateSettings { $0.breakdownMeasure = value } }
        )
    }

    private var seriesLimitBinding: Binding<Int> {
        Binding(
            get: { model.settings.seriesLimit },
            set: { value in model.updateSettings { $0.seriesLimit = value } }
        )
    }

    private var intervalBinding: Binding<TimeInterval> {
        Binding(
            get: { model.settings.refreshInterval },
            set: { value in model.updateSettings { $0.refreshInterval = value } }
        )
    }

    private var timeZoneBinding: Binding<TimeZoneMode> {
        Binding(
            get: { model.settings.timeZoneMode },
            set: { value in model.updateSettings { $0.timeZoneMode = value } }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.settings.launchAtLogin },
            set: { value in
                do {
                    try LaunchAtLogin.set(enabled: value)
                    launchAtLoginError = nil
                    model.updateSettings { $0.launchAtLogin = value }
                } catch {
                    launchAtLoginError = "Could not change login item: \(error.localizedDescription)"
                }
            }
        )
    }
}

// MARK: - Provider row

private struct ProviderRow: View {
    let model: AppModel
    let descriptor: ProviderDescriptor

    @State private var draft = ""
    @State private var status: Status?
    @State private var isBusy = false

    private enum Status: Equatable {
        case success(String)
        case info(String)
        case failure(String)
    }

    private var isEnabled: Bool {
        model.settings.enabledProviders.contains(descriptor.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(isOn: enabledBinding) {
                HStack(spacing: 6) {
                    Text(descriptor.displayName)
                        .fontWeight(.medium)
                    if descriptor.isSynthetic {
                        Text("SAMPLE")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
            }

            Text(descriptor.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isEnabled, !descriptor.isSynthetic {
                credentialControls
            }

            statusLine
        }
        .padding(.vertical, 4)
        .onAppear(perform: loadExistingCapabilities)
    }

    private var credentialControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                SecureField(descriptor.credentialPlaceholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit(save)

                Button("Save", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
                    .controlSize(.small)

                Button("Test", action: test)
                    .disabled(isBusy)
                    .controlSize(.small)

                if model.hasCredential(descriptor.id) {
                    Button("Remove") {
                        model.removeCredential(for: descriptor.id)
                        draft = ""
                        status = .info("Credential removed.")
                    }
                    .controlSize(.small)
                }
            }

            HStack(spacing: 6) {
                if let url = descriptor.credentialURL {
                    Link("Create \(descriptor.credentialLabel.lowercased()) ↗", destination: url)
                        .font(.caption)
                }
                if model.hasCredential(descriptor.id) {
                    Text("· Key stored in Keychain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case let .success(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case let .info(message):
            Label(message, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case let .failure(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            if isEnabled, let hint = descriptor.upgradeHint, !model.hasCredential(descriptor.id) {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { enabled in
                model.updateSettings { settings in
                    if enabled {
                        if !settings.enabledProviders.contains(descriptor.id) {
                            settings.enabledProviders.append(descriptor.id)
                        }
                    } else {
                        settings.enabledProviders.removeAll { $0 == descriptor.id }
                    }
                }
                if !enabled {
                    status = nil
                }
            }
        )
    }

    private func loadExistingCapabilities() {
        guard isEnabled, let capability = model.capability(for: descriptor.id) else { return }
        status = .info(Self.describe(capability))
    }

    private func save() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let error = model.saveCredential(value, for: descriptor.id) {
            status = .failure(error)
            return
        }
        draft = ""
        test()
    }

    private func test() {
        isBusy = true
        let override = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let result = await model.probe(descriptor.id, credentialOverride: override.isEmpty ? nil : override)
            isBusy = false
            switch result {
            case let .success(capability):
                status = .success(Self.describe(capability))
            case let .failure(error):
                status = .failure(error.errorDescription ?? "Could not verify credential.")
            }
            model.refresh(reason: "probe", force: true)
        }
    }

    static func describe(_ capability: ProviderCapabilities) -> String {
        var parts: [String] = []
        let windows = SpendWindow.allCases.filter { capability.supports($0) }
        if windows.count == SpendWindow.allCases.count {
            parts.append("All windows available")
        } else if !windows.isEmpty {
            parts.append("Windows: \(windows.map(\.title).joined(separator: ", "))")
        }
        if capability.hasModelBreakdown {
            parts.append("per-model breakdown")
        } else if capability.hasProviderBreakdown {
            parts.append("per-provider breakdown")
        }
        var message = parts.joined(separator: " · ")
        if let first = capability.notes.first {
            message += message.isEmpty ? first : " — \(first)"
        }
        return message.isEmpty ? "Connected." : message
    }
}
