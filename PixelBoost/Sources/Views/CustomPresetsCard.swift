import SwiftUI

/// Settings card for creating/browsing/deleting named model+overlap
/// presets, backed by `CustomPresetService` — server-only, so this card is
/// silently empty (not an error) until a server is configured.
struct CustomPresetsCard: View {
    @State private var presets: [CustomPreset] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isPresentingNewPreset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PBSectionLabel(title: "Custom Presets")
            PBCard {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12.5))
                        .foregroundStyle(PBColor.bad)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                } else if presets.isEmpty && !isLoading {
                    Text("No custom presets yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(PBColor.inkDim)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
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
            PBFootnote(text: "Named model + overlap combinations beyond Fast/Standard/Best, stored on your configured server.")
        }
        .task { await load() }
        .sheet(isPresented: $isPresentingNewPreset) {
            NewPresetSheet { name, modelName, overlap in
                await create(name: name, modelName: modelName, overlap: overlap)
            }
        }
    }

    private func presetRow(_ preset: CustomPreset) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
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
                Text("\(modelDisplayName(preset.model_name)) · overlap \(preset.overlap)")
                    .font(.system(size: 12))
                    .foregroundStyle(PBColor.inkDim)
            }
            Spacer()
            Button(role: .destructive) { delete(preset) } label: {
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

    private func load() async {
        isLoading = true
        do {
            presets = try await CustomPresetService.fetchOwn()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func delete(_ preset: CustomPreset) {
        presets.removeAll { $0.id == preset.id }
        Task { try? await CustomPresetService.delete(id: preset.id) }
    }

    private func create(name: String, modelName: String, overlap: Int) async {
        do {
            _ = try await CustomPresetService.save(name: name, modelName: modelName, overlap: overlap)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct NewPresetSheet: View {
    let onSave: (String, String, Int) async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var modelChoice: UpscaleModelChoice = .generalPhoto
    @State private var overlap: Double = 8

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Model", selection: $modelChoice) {
                    // Auto excluded — a preset saves one concrete model +
                    // overlap, and Auto never resolves to a model of its own.
                    ForEach(UpscaleModelChoice.allCases.filter { $0 != .auto }) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                VStack(alignment: .leading) {
                    Text("Overlap: \(Int(overlap))")
                    Slider(value: $overlap, in: 0...32, step: 1)
                }
            }
            .navigationTitle("New Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await onSave(name, modelChoice.modelName, Int(overlap))
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
