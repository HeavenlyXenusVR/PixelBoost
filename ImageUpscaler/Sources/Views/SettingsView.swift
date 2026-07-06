import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var provider: UpscalerProvider
    @AppStorage(ServerConfig.baseURLDefaultsKey) private var serverURLString: String = ServerConfig.defaultBaseURLString
    @AppStorage(ServerConfig.apiKeyDefaultsKey) private var apiKeyString: String = ""
    @AppStorage(Haptics.enabledDefaultsKey) private var hapticsEnabled: Bool = true
    @State private var backupRestoreMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("Quality", selection: $provider.quality) {
                    ForEach(UpscaleQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Picker("Model", selection: $provider.modelChoice) {
                    ForEach(UpscaleModelChoice.allCases) { choice in
                        Text(choice.isBundled ? choice.displayName : "\(choice.displayName) (not bundled)")
                            .tag(choice)
                    }
                }
                if provider.isLoadingModel {
                    HStack {
                        ProgressView()
                        Text("Loading model…")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Upscale Quality")
            } footer: {
                Text("Fast skips the model entirely (plain resampling, instant). Standard/Best trade speed for tile-seam quality. Model only matters when Quality isn't Fast.")
            }

            CustomPresetsSection()

            Section {
                Toggle("Haptic Feedback", isOn: $hapticsEnabled)
            } header: {
                Text("Feedback")
            }

            Section {
                TextField("https://your-server.example.com", text: $serverURLString)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API key (optional)", text: $apiKeyString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Upscaler-Bridge Server")
            } footer: {
                Text("Optional. If set, every upscale (success or failure) is logged here — source image size, technique/model used, tile config, timing. Leave the URL empty to disable logging entirely. Release builds from CI have a key baked in automatically; leave the API key field blank to use that default, or set one here to override it. See server/README.md in the repo for how to deploy one.")
            }

            Section {
                Button {
                    Task { await backupSettings() }
                } label: {
                    Label("Backup Settings to Server", systemImage: "icloud.and.arrow.up")
                }
                Button {
                    Task { await restoreSettings() }
                } label: {
                    Label("Restore Settings from Server", systemImage: "icloud.and.arrow.down")
                }
            } header: {
                Text("Backup & Restore")
            } footer: {
                Text("Manually save/load your haptics, model, and quality settings on your configured server. No accounts, so this is one backup slot per device, not automatic sync.")
            }

            Section {
                LabeledContent("Device ID", value: DeviceIdentity.current)
            } header: {
                Text("This Device")
            } footer: {
                Text("A random identifier generated once per install — there are no user accounts, so this is just how history entries are grouped per device.")
            }

            Section {
                LabeledContent("Version", value: appVersion)
                Link(destination: URL(string: "https://github.com/HeavenlyXenusVR/ImageUpscaler")!) {
                    Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            } header: {
                Text("About")
            } footer: {
                Text("Includes a Core ML conversion of Real-ESRGAN (© Xintao Wang, BSD-3-Clause). Full license text and conversion details: Models/THIRD_PARTY_NOTICES.md in the repo above.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Settings Backup", isPresented: Binding(
            get: { backupRestoreMessage != nil },
            set: { isPresented in if !isPresented { backupRestoreMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(backupRestoreMessage ?? "")
        }
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func backupSettings() async {
        do {
            try await DeviceSettingsService.backup(
                hapticsEnabled: hapticsEnabled, modelChoice: provider.modelChoice, quality: provider.quality
            )
            backupRestoreMessage = "Settings backed up."
        } catch {
            backupRestoreMessage = error.localizedDescription
        }
    }

    private func restoreSettings() async {
        do {
            let backup = try await DeviceSettingsService.restore()
            hapticsEnabled = backup.haptics_enabled
            if let model = UpscaleModelChoice(rawValue: backup.model_choice) {
                provider.modelChoice = model
            }
            if let quality = UpscaleQuality(rawValue: backup.quality) {
                provider.quality = quality
            }
            backupRestoreMessage = "Settings restored."
        } catch {
            backupRestoreMessage = error.localizedDescription
        }
    }
}

#Preview {
    let provider = UpscalerProvider()
    NavigationStack { SettingsView() }
        .environmentObject(provider)
}
