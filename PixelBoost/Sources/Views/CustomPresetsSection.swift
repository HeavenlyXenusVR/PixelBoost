import SwiftUI

/// Settings section for creating/browsing/deleting named model+overlap
/// presets, backed by `CustomPresetService` — server-only, so this section
/// is silently empty (not an error) until a server is configured.
struct CustomPresetsSection: View {
    @State private var presets: [CustomPreset] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isPresentingNewPreset = false

    var body: some View {
        Section {
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if presets.isEmpty && !isLoading {
                Text("No custom presets yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(presets) { preset in
                    LabeledContent(preset.name, value: "\(modelDisplayName(preset.model_name)) · overlap \(preset.overlap)")
                }
                .onDelete(perform: delete)
            }

            Button {
                isPresentingNewPreset = true
            } label: {
                Label("New Preset", systemImage: "plus")
            }
        } header: {
            Text("Custom Presets")
        } footer: {
            Text("Named model + overlap combinations beyond Fast/Standard/Best, stored on your configured server.")
        }
        .task { await load() }
        .sheet(isPresented: $isPresentingNewPreset) {
            NewPresetSheet { name, modelName, overlap in
                await create(name: name, modelName: modelName, overlap: overlap)
            }
        }
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

    private func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { presets[$0] }
        presets.remove(atOffsets: offsets)
        Task {
            for preset in toDelete {
                try? await CustomPresetService.delete(id: preset.id)
            }
        }
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
                    ForEach(UpscaleModelChoice.allCases) { choice in
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
