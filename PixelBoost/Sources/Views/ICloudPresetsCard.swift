import SwiftUI

/// Settings card for creating/browsing/deleting named model+overlap
/// presets, backed by `ICloudPresetStore` — synced via iCloud's key-value
/// store, so unlike `CustomPresetsCard` (server-only) this works with no
/// server configured, as long as the device is signed into iCloud.
struct ICloudPresetsCard: View {
    @ObservedObject private var store = ICloudPresetStore.shared
    @State private var isPresentingNewPreset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PBSectionLabel(title: "iCloud Presets")
            PBCard {
                if store.presets.isEmpty {
                    Text("No iCloud presets yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(PBColor.inkDim)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(store.presets.enumerated()), id: \.element.id) { index, preset in
                        if index > 0 { PBRowDivider() }
                        presetRow(preset)
                    }
                }
                PBRowDivider()
                Button {
                    isPresentingNewPreset = true
                } label: {
                    PBCardRow(icon: "plus", iconTint: PBColor.accent, label: "New Preset")
                }
                .buttonStyle(.plain)
            }
            PBFootnote(text: "Named model + overlap combinations synced across your devices via iCloud — no server or account needed, just being signed into iCloud. Separate from the server-backed Custom Presets above; if the latest edit on two devices happens at nearly the same time, whichever syncs last wins.")
        }
        .sheet(isPresented: $isPresentingNewPreset) {
            NewICloudPresetSheet { name, modelName, overlap in
                store.save(name: name, modelName: modelName, overlap: overlap)
            }
        }
    }

    private func presetRow(_ preset: ICloudPreset) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "icloud")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PBColor.accent)
                .frame(width: 30, height: 30)
                .background(PBColor.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PBColor.ink)
                Text("\(modelDisplayName(preset.modelName)) · overlap \(preset.overlap)")
                    .font(.system(size: 12))
                    .foregroundStyle(PBColor.inkDim)
            }
            Spacer()
            Button(role: .destructive) { store.delete(preset) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(PBColor.bad)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func modelDisplayName(_ modelName: String) -> String {
        UpscaleModelChoice.allCases.first { $0.modelName == modelName }?.displayName ?? modelName
    }
}

private struct NewICloudPresetSheet: View {
    let onSave: (String, String, Int) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var modelChoice: UpscaleModelChoice = .generalPhoto
    @State private var overlap: Double = 8

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Model", selection: $modelChoice) {
                    ForEach(UpscaleModelChoice.allCases.filter { $0 != .auto }) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                VStack(alignment: .leading) {
                    Text("Overlap: \(Int(overlap))")
                    Slider(value: $overlap, in: 0...32, step: 1)
                }
            }
            .navigationTitle("New iCloud Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name, modelChoice.modelName, Int(overlap))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
