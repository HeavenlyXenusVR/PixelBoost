import SwiftUI

/// The upscale, live: the original sits dimmed underneath while finished
/// tiles of real model output are painted over it as they complete, with
/// the tile grid and the batch currently in flight outlined on top. Every
/// pixel you see fill in is a pixel the model has actually processed.
///
/// Cheap by construction — frames arrive at most a few times a second
/// (`UpscalePower.previewInterval`), the preview is ≤900px, and the grid is
/// one `Canvas` path rather than a view per tile.
struct LiveUpscaleCanvas: View {
    let source: UIImage
    let frame: UpscaleLiveFrame?
    let isPaused: Bool

    var body: some View {
        ZStack {
            Image(uiImage: source)
                .resizable()
                .saturation(0)
                .opacity(0.35)

            if let preview = frame?.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.medium)
            }

            if let frame {
                Canvas { context, size in
                    // Grid only while it's still legible.
                    if frame.columns * frame.rows <= 1600 {
                        var grid = Path()
                        for column in 1..<max(1, frame.columns) {
                            let x = size.width * CGFloat(column) / CGFloat(frame.columns)
                            grid.move(to: CGPoint(x: x, y: 0))
                            grid.addLine(to: CGPoint(x: x, y: size.height))
                        }
                        for row in 1..<max(1, frame.rows) {
                            let y = size.height * CGFloat(row) / CGFloat(frame.rows)
                            grid.move(to: CGPoint(x: 0, y: y))
                            grid.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        context.stroke(grid, with: .color(.white.opacity(0.07)), lineWidth: 0.5)
                    }
                    if frame.tilesDone < frame.tilesTotal {
                        let region = frame.activeRegion
                        let rect = CGRect(
                            x: region.minX * size.width, y: region.minY * size.height,
                            width: max(3, region.width * size.width), height: max(3, region.height * size.height)
                        )
                        context.fill(Path(rect), with: .color(PBColor.accent.opacity(0.25)))
                        context.stroke(Path(rect), with: .color(PBColor.accent), lineWidth: 1.5)
                    }
                }
                .allowsHitTesting(false)
            }

            if isPaused {
                Label("Paused", systemImage: "pause.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.6), in: Capsule())
            }
        }
        .aspectRatio(source.size.width / max(1, source.size.height), contentMode: .fit)
    }
}
