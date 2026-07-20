import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var provider: UpscalerProvider
    @AppStorage(ServerConfig.baseURLDefaultsKey) private var serverURLString: String = ServerConfig.defaultBaseURLString
    @AppStorage(ServerConfig.apiKeyDefaultsKey) private var apiKeyString: String = ""
    @AppStorage(Haptics.enabledDefaultsKey) private var hapticsEnabled: Bool = true
    @State private var backupRestoreMessage: String?
    @State private var isPresentingModelPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PBSectionLabel(title: "Upscale Quality")
                PBCard {
                    qualityRow
                    PBRowDivider()
                    modelRow
                    PBRowDivider()
                    scaleRow
                    PBRowDivider()
                    denoiseRow
                    PBRowDivider()
                    sharpenRow
                    if provider.modelChoice == .auto, let picked = provider.lastAutoSelectedModel {
                        PBRowDivider()
                        PBCardRow(icon: "checkmark.circle", iconTint: PBColor.good, label: "Last batch auto pick", value: picked.displayName)
                    }
                    if provider.isTestingModels {
                        PBRowDivider()
                        loadingRow(text: "Testing models…")
                    } else if provider.isLoadingModel {
                        PBRowDivider()
                        loadingRow(text: "Loading model…")
                    }
                }
                PBFootnote(text: "Auto runs every bundled model on the whole photo and shows you all of them side by side to pick from — Batch Upscale (nobody's watching per photo there) still picks automatically via a quick sharpness test instead. Fast skips the model entirely (plain resampling, instant). Standard/Best trade speed for tile-seam quality. Output Scale always analyzes at each model's native 4x, then resizes down to your chosen size — 2x/3x still benefit from the model's full detail, not a shortcut.")

                CustomPresetsCard()
                ICloudPresetsCard()

                PBSectionLabel(title: "Export")
                PBCard {
                    exportFormatRow
                    if provider.exportFormat.usesQuality {
                        PBRowDivider()
                        exportQualityRow
                    }
                }
                PBFootnote(text: "Auto keeps a photo's transparency if it has any (a Cutout result, say) by saving as PNG, and uses JPEG otherwise — pick HEIC or JPEG to force a specific format (both lose any transparency), or PNG to always keep it lossless. Applies to every save, single photo or batch.")

                PBSectionLabel(title: "Watermark")
                PBCard {
                    Toggle(isOn: $provider.watermarkEnabled) {
                        Text("Add Watermark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(PBColor.ink)
                    }
                    .tint(PBColor.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    if provider.watermarkEnabled {
                        PBRowDivider()
                        fieldRow(icon: "textformat") {
                            TextField("Your name or @handle", text: $provider.watermarkText)
                                .foregroundStyle(PBColor.ink)
                        }
                        PBRowDivider()
                        watermarkPositionRow
                        PBRowDivider()
                        watermarkOpacityRow
                    }
                }
                PBFootnote(text: "Draws your text over the bottom-right (or wherever you pick) corner of every saved photo — single, batch, and Compare Models' \"Save All.\" A signature/credit line, not copy protection.")

                PBSectionLabel(title: "Automation")
                PBCard {
                    Toggle(isOn: $provider.autoSaveEnabled) {
                        Text("Auto-Save After Upscale")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(PBColor.ink)
                    }
                    .tint(PBColor.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    PBRowDivider()
                    Toggle(isOn: $provider.preserveOriginal) {
                        Text("Preserve Original")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(PBColor.ink)
                    }
                    .tint(PBColor.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    PBRowDivider()
                    Toggle(isOn: $provider.addToAlbumEnabled) {
                        Text("Add to PixelBoost Album")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(PBColor.ink)
                    }
                    .tint(PBColor.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                PBFootnote(text: "Auto-Save saves a single-photo Upscale result the moment it finishes, no Save tap needed (Batch already always saves per photo). Preserve Original always adds a new photo instead of overwriting the one you picked, undoing the overwrite-by-default behavior everywhere else in the app. Add to PixelBoost Album also files every save into a \"PixelBoost\" album in Photos, created the first time it's needed, so edited photos are easy to find as a set.")

                PBSectionLabel(title: "Appearance")
                PBCard {
                    accentThemeRow
                    PBRowDivider()
                    defaultTabRow
                }
                PBFootnote(text: "Accent color takes effect the next time you open PixelBoost, not live — every tab stays mounted for the app's whole session, so nothing re-reads this choice until a fresh launch.")

                PBSectionLabel(title: "Feedback")
                PBCard {
                    Toggle(isOn: $hapticsEnabled) {
                        Text("Haptic Feedback")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(PBColor.ink)
                    }
                    .tint(PBColor.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }

                PBSectionLabel(title: "Upscaler-Bridge Server")
                PBCard {
                    fieldRow(icon: "network") {
                        TextField("https://your-server.example.com", text: $serverURLString)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(PBColor.ink)
                    }
                    PBRowDivider()
                    fieldRow(icon: "key") {
                        SecureField("API key (optional)", text: $apiKeyString)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(PBColor.ink)
                    }
                }
                PBFootnote(text: "Optional. If set, every upscale (success or failure) is logged here — source image size, technique/model used, tile config, timing. Leave the URL empty to disable logging entirely. Release builds from CI have a key baked in automatically; leave the API key field blank to use that default, or set one here to override it. See server/README.md in the repo for how to deploy one.")

                PBSectionLabel(title: "Backup & Restore")
                PBCard {
                    Button {
                        Task { await backupSettings() }
                    } label: {
                        PBCardRow(icon: "icloud.and.arrow.up", label: "Backup Settings to Server")
                    }
                    .buttonStyle(.plain)
                    PBRowDivider()
                    Button {
                        Task { await restoreSettings() }
                    } label: {
                        PBCardRow(icon: "icloud.and.arrow.down", label: "Restore Settings from Server")
                    }
                    .buttonStyle(.plain)
                }
                PBFootnote(text: "Manually save/load your haptics, model, and quality settings on your configured server. No accounts, so this is one backup slot per device, not automatic sync.")

                PBSectionLabel(title: "This Device")
                PBCard {
                    PBCardRow(icon: "person.badge.key", label: "Device ID", value: DeviceIdentity.current)
                }
                PBFootnote(text: "A random identifier generated once per install — there are no user accounts, so this is just how history entries are grouped per device.")

                PBSectionLabel(title: "About")
                PBCard {
                    PBCardRow(icon: "info.circle", label: "Version", value: appVersion)
                    PBRowDivider()
                    Link(destination: URL(string: "https://github.com/HeavenlyXenusVR/PixelBoost")!) {
                        PBCardRow(icon: "chevron.left.forwardslash.chevron.right", iconTint: PBColor.accent, label: "Source on GitHub")
                    }
                }
                PBFootnote(text: "Includes a Core ML conversion of Real-ESRGAN (© Xintao Wang, BSD-3-Clause). Full license text and conversion details: Models/THIRD_PARTY_NOTICES.md in the repo above.")
            }
            .padding(16)
        }
        .background(PBColor.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(PBColor.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $isPresentingModelPicker) {
            ModelPickerView(provider: provider)
        }
        .alert("Settings Backup", isPresented: Binding(
            get: { backupRestoreMessage != nil },
            set: { isPresented in if !isPresented { backupRestoreMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(backupRestoreMessage ?? "")
        }
        .preferredColorScheme(.dark)
    }

    private var qualityRow: some View {
        Menu {
            ForEach(UpscaleQuality.allCases) { quality in
                Button(quality.displayName) { provider.quality = quality }
            }
        } label: {
            PBCardRow(icon: "dial.medium", label: "Quality", value: "\(provider.quality.displayName) ›")
        }
        .buttonStyle(.plain)
    }

    private var modelRow: some View {
        Button {
            isPresentingModelPicker = true
        } label: {
            PBCardRow(icon: "sparkles", iconTint: PBColor.accent2, label: "Model", value: "\(provider.modelChoice.displayName) ›")
        }
        .buttonStyle(.plain)
    }

    private var scaleRow: some View {
        Menu {
            ForEach(UpscaleFactor.allCases) { factor in
                Button(factor.displayName) { provider.scaleFactor = factor }
            }
        } label: {
            PBCardRow(icon: "arrow.up.left.and.arrow.down.right", label: "Output Scale", value: "\(provider.scaleFactor.displayName) ›")
        }
        .buttonStyle(.plain)
    }

    private var denoiseRow: some View {
        Toggle(isOn: $provider.denoiseBeforeUpscale) {
            Text("Denoise Before Upscale")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PBColor.ink)
        }
        .tint(PBColor.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var sharpenRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sharpen After Upscale")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PBColor.ink)
                Spacer()
                Text(provider.sharpenAmount > 0 ? "\(Int(provider.sharpenAmount * 100))%" : "Off")
                    .font(.system(size: 13))
                    .foregroundStyle(PBColor.inkDim)
            }
            Slider(value: $provider.sharpenAmount, in: 0...1)
                .tint(PBColor.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var watermarkPositionRow: some View {
        Menu {
            ForEach(WatermarkPosition.allCases) { position in
                Button(position.displayName) { provider.watermarkPosition = position }
            }
        } label: {
            PBCardRow(icon: "text.alignleft", label: "Position", value: "\(provider.watermarkPosition.displayName) ›")
        }
        .buttonStyle(.plain)
    }

    private var watermarkOpacityRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Opacity")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PBColor.ink)
                Spacer()
                Text("\(Int(provider.watermarkOpacity * 100))%")
                    .font(.system(size: 13))
                    .foregroundStyle(PBColor.inkDim)
            }
            Slider(value: $provider.watermarkOpacity, in: 0.1...1)
                .tint(PBColor.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var accentThemeRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accent Color")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PBColor.ink)
            HStack(spacing: 10) {
                ForEach(AccentTheme.allCases) { theme in
                    Button {
                        provider.accentTheme = theme
                        Haptics.lightImpact()
                    } label: {
                        Circle()
                            .fill(theme.primary)
                            .frame(width: 30, height: 30)
                            .overlay(
                                Circle().strokeBorder(
                                    provider.accentTheme == theme ? PBColor.ink : Color.clear, lineWidth: 2
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var defaultTabRow: some View {
        Menu {
            ForEach(AppTab.allCases) { tab in
                Button(tab.title) { provider.defaultTab = tab }
            }
        } label: {
            PBCardRow(icon: "house", label: "Open To", value: "\(provider.defaultTab.title) ›")
        }
        .buttonStyle(.plain)
    }

    private var exportFormatRow: some View {
        Menu {
            ForEach(ExportFormat.allCases) { format in
                Button(format.displayName) { provider.exportFormat = format }
            }
        } label: {
            PBCardRow(icon: "square.and.arrow.up", label: "Format", value: "\(provider.exportFormat.displayName) ›")
        }
        .buttonStyle(.plain)
    }

    private var exportQualityRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Quality")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PBColor.ink)
                Spacer()
                Text("\(Int(provider.exportQuality * 100))%")
                    .font(.system(size: 13))
                    .foregroundStyle(PBColor.inkDim)
            }
            Slider(value: $provider.exportQuality, in: 0.5...1)
                .tint(PBColor.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func loadingRow(text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().tint(PBColor.accent)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(PBColor.inkDim)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func fieldRow<Field: View>(icon: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PBColor.accent)
                .frame(width: 30, height: 30)
                .background(PBColor.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
            field()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
