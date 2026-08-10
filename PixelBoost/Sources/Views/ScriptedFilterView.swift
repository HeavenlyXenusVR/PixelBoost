import SwiftUI

/// Write/paste a small Lua script defining `apply(r, g, b, a)` (each
/// 0...1) and run it over the current photo, pixel by pixel — a
/// user-scriptable filter, sandboxed via `LuaFilterEngine`. Same
/// persistent-tab/Apply-bakes-and-resets shape as every other editing tab;
/// no Cancel/Done step. Saved scripts are named and kept locally
/// (`ScriptedFilterStore`) so they're there again next launch.
struct ScriptedFilterView: View {
    @EnvironmentObject private var viewModel: UpscalerViewModel

    @State private var code: String = ScriptedFilterStore.defaultScripts[0].code
    @State private var scriptName: String = ScriptedFilterStore.defaultScripts[0].name
    @State private var savedScripts: [SavedLuaScript] = ScriptedFilterStore.load()
    @State private var previewImage: UIImage?
    @State private var previewSource: UIImage?
    @State private var lastBase: UIImage?
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var showingSavedList = false

    var body: some View {
        NavigationStack {
            Group {
                if previewSource != nil {
                    ScrollView {
                        VStack(spacing: 20) {
                            PBImageFrame {
                                Group {
                                    if let previewImage {
                                        Image(uiImage: previewImage)
                                            .resizable()
                                            .scaledToFit()
                                    } else if let previewSource {
                                        Image(uiImage: previewSource)
                                            .resizable()
                                            .scaledToFit()
                                            .opacity(0.4)
                                    }
                                }
                                .frame(maxHeight: 280)
                            }

                            HStack {
                                TextField("Script name", text: $scriptName)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(PBColor.ink)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(PBColor.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                Button {
                                    showingSavedList = true
                                } label: {
                                    Image(systemName: "tray.full")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(PBColor.ink)
                                        .frame(width: 38, height: 38)
                                        .background(PBColor.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }

                            TextEditor(text: $code)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(PBColor.ink)
                                .scrollContentBackground(.hidden)
                                .frame(height: 200)
                                .padding(8)
                                .background(PBColor.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(PBColor.line, lineWidth: 1)
                                )

                            Text("Must define apply(r, g, b, a) returning 4 numbers 0...1. Runs at up to \(Int(LuaFilterEngine.maxAppliedDimension))px on the longest side, capped to \(Int(LuaFilterEngine.timeLimit))s.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(PBColor.inkFaint)

                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(PBColor.bad)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            HStack(spacing: 10) {
                                Button {
                                    Haptics.lightImpact()
                                    saveScript()
                                } label: {
                                    Label("Save Script", systemImage: "square.and.arrow.down")
                                }
                                .buttonStyle(.pbGhost)

                                Button {
                                    Haptics.lightImpact()
                                    Task { await runPreview() }
                                } label: {
                                    if isRunning {
                                        ProgressView().tint(.white)
                                    } else {
                                        Label("Preview", systemImage: "play.fill")
                                    }
                                }
                                .buttonStyle(.pbGhost)
                                .disabled(isRunning)
                            }

                            Button {
                                Haptics.lightImpact()
                                Task { await applyToResult() }
                            } label: {
                                Label("Apply", systemImage: "checkmark")
                            }
                            .buttonStyle(.pbGradient)
                            .disabled(isRunning)
                        }
                        .padding(20)
                    }
                } else {
                    emptyState
                }
            }
            .pbReserveTabBarSpace()
            .background(PBColor.background.ignoresSafeArea())
            .navigationTitle("Scripted Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PBColor.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onChange(of: viewModel.imageVersion) { _, _ in refreshFromCurrentImage() }
            .onAppear { refreshFromCurrentImage() }
            .sheet(isPresented: $showingSavedList) {
                savedScriptsSheet
            }
        }
    }

    private func refreshFromCurrentImage() {
        let current = viewModel.resultImage ?? viewModel.sourceImage
        guard let current else {
            lastBase = nil
            previewSource = nil
            previewImage = nil
            return
        }
        guard current !== lastBase else { return }
        lastBase = current
        previewSource = Self.downscaled(current, maxDimension: 500)
        previewImage = nil
        errorMessage = nil
    }

    private func runPreview() async {
        guard let previewSource else { return }
        isRunning = true
        errorMessage = nil
        switch await Self.run(code, on: previewSource) {
        case .success(let image): previewImage = image
        case .failure(let error): errorMessage = error.localizedDescription
        }
        isRunning = false
    }

    /// Runs against the full-resolution current result/source (capped to
    /// `LuaFilterEngine.maxAppliedDimension`, same as the preview path) and
    /// writes back to the shared result — bumps `imageVersion`, which
    /// re-derives the preview from the new baseline on its own.
    private func applyToResult() async {
        guard let current = viewModel.resultImage ?? viewModel.sourceImage else { return }
        isRunning = true
        errorMessage = nil
        switch await Self.run(code, on: current) {
        case .success(let image):
            viewModel.resultImage = image
            Haptics.success()
        case .failure(let error):
            errorMessage = error.localizedDescription
            Haptics.error()
        }
        isRunning = false
    }

    /// Compiles and runs `script` off the main actor — a script's
    /// `apply(r, g, b, a)` runs synchronously once per pixel with no
    /// `await` inside it (see `LuaFilterEngine.apply(to:)`), so calling it
    /// straight from an `@MainActor`-implicit `Task { }` body would stall
    /// the UI thread for however long that loop takes.
    private static func run(_ script: String, on image: UIImage) async -> Result<UIImage, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let engine = try LuaFilterEngine()
                try engine.compile(script)
                return .success(try engine.apply(to: image))
            } catch {
                return .failure(error)
            }
        }.value
    }

    private func saveScript() {
        let trimmedName = scriptName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        if let index = savedScripts.firstIndex(where: { $0.name == trimmedName }) {
            savedScripts[index].code = code
        } else {
            savedScripts.append(SavedLuaScript(name: trimmedName, code: code))
        }
        ScriptedFilterStore.save(savedScripts)
    }

    private var savedScriptsSheet: some View {
        NavigationStack {
            List {
                ForEach(savedScripts) { script in
                    Button {
                        code = script.code
                        scriptName = script.name
                        errorMessage = nil
                        showingSavedList = false
                    } label: {
                        Text(script.name)
                            .foregroundStyle(PBColor.ink)
                    }
                }
                .onDelete { indices in
                    savedScripts.remove(atOffsets: indices)
                    ScriptedFilterStore.save(savedScripts)
                }
            }
            .navigationTitle("Saved Scripts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showingSavedList = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        PBEmptyState(icon: "chevron.left.slash.chevron.right", message: "Choose a photo on the Upscale tab first.")
    }

    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        guard scale < 1 else { return image }
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

#Preview {
    let provider = UpscalerProvider()
    ScriptedFilterView()
        .environmentObject(provider)
        .environmentObject(UpscalerViewModel(provider: provider))
}
