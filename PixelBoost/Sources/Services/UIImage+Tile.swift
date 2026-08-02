import UIKit

extension UIImage {
    /// Crops a `rect`-sized region out of this image, where `rect` uses
    /// ordinary top-left-origin, y-down pixel coordinates (i.e. row 0 is the
    /// top row) — the same convention `ImageTiler` plans in. `rect` may
    /// extend past this image's bounds (e.g. the last tile in a row/column);
    /// anything outside the source image comes back transparent. For a
    /// super-resolution model's *input* tile crop specifically, prefer
    /// `croppedEdgeReplicated(to:)` below instead — see its doc comment for
    /// why a hard transparent edge is a real, measured defect there, not
    /// just a discarded margin.
    func cropped(to rect: CGRect) -> UIImage {
        // scale = 1 is essential here: without it, UIGraphicsImageRenderer
        // defaults to the main screen's scale (2x/3x) and every tile would
        // come out that many times larger than the pixel dimensions the
        // model/tiler expect.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)
        return renderer.image { _ in
            self.draw(at: CGPoint(x: -rect.origin.x, y: -rect.origin.y))
        }
    }

    /// Like `cropped(to:)`, but any part of `rect` that falls outside this
    /// image's own bounds is filled by stretching the nearest 1px edge
    /// strip of real content into that margin, instead of coming back
    /// transparent.
    ///
    /// This matters more than it sounds: `ImageTiler` gives every tile
    /// touching a photo's outer border a `sourceRect` that extends past the
    /// image (by exactly `overlap` pixels) so the model gets full-size
    /// context on all four sides. A CNN's receptive field means the blank
    /// pixels right next to real content still influence the model's
    /// output *inside* the kept region, not just the discarded margin — a
    /// side-by-side test against a non-tiled reference run of the same
    /// model measured roughly 8x higher pixel divergence in the outermost
    /// `overlap`-pixel band of a tiled result than in the interior,
    /// visible as a dark/smudged fringe hugging every photo's edge. Edge
    /// replication gives the model plausible (if flat, since it's just a
    /// stretched single pixel strip, not true mirroring) context instead
    /// of a hard blank boundary, which is the same fix Real-ESRGAN's own
    /// `--tile` reference implementation and most other tiled-inference
    /// setups use.
    func croppedEdgeReplicated(to rect: CGRect) -> UIImage {
        let bounds = CGRect(origin: .zero, size: size)
        guard bounds.width > 0, bounds.height > 0 else { return cropped(to: rect) }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)
        return renderer.image { _ in
            self.draw(at: CGPoint(x: -rect.origin.x, y: -rect.origin.y))

            let leftGap = bounds.minX - rect.minX
            let topGap = bounds.minY - rect.minY
            let rightGap = rect.maxX - bounds.maxX
            let bottomGap = rect.maxY - bounds.maxY

            let vMinY = max(bounds.minY, rect.minY)
            let vMaxY = min(bounds.maxY, rect.maxY)
            let vHeight = max(0, vMaxY - vMinY)
            let hMinX = max(bounds.minX, rect.minX)
            let hMaxX = min(bounds.maxX, rect.maxX)
            let hWidth = max(0, hMaxX - hMinX)

            // Edges: a thin real strip along whichever side ran off the
            // image, stretched to fill that side's gap.
            if leftGap > 0, vHeight > 0 {
                let strip = self.cropped(to: CGRect(x: bounds.minX, y: vMinY, width: 1, height: vHeight))
                strip.draw(in: CGRect(x: 0, y: vMinY - rect.minY, width: leftGap, height: vHeight))
            }
            if rightGap > 0, vHeight > 0 {
                let strip = self.cropped(to: CGRect(x: bounds.maxX - 1, y: vMinY, width: 1, height: vHeight))
                strip.draw(in: CGRect(x: rect.width - rightGap, y: vMinY - rect.minY, width: rightGap, height: vHeight))
            }
            if topGap > 0, hWidth > 0 {
                let strip = self.cropped(to: CGRect(x: hMinX, y: bounds.minY, width: hWidth, height: 1))
                strip.draw(in: CGRect(x: hMinX - rect.minX, y: 0, width: hWidth, height: topGap))
            }
            if bottomGap > 0, hWidth > 0 {
                let strip = self.cropped(to: CGRect(x: hMinX, y: bounds.maxY - 1, width: hWidth, height: 1))
                strip.draw(in: CGRect(x: hMinX - rect.minX, y: rect.height - bottomGap, width: hWidth, height: bottomGap))
            }
            // Corners: a single real edge pixel, stretched to fill the
            // corner gap — flat, but real (clamped) color rather than
            // transparent, matching how the edges above are filled.
            if leftGap > 0, topGap > 0 {
                let corner = self.cropped(to: CGRect(x: bounds.minX, y: bounds.minY, width: 1, height: 1))
                corner.draw(in: CGRect(x: 0, y: 0, width: leftGap, height: topGap))
            }
            if rightGap > 0, topGap > 0 {
                let corner = self.cropped(to: CGRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: 1))
                corner.draw(in: CGRect(x: rect.width - rightGap, y: 0, width: rightGap, height: topGap))
            }
            if leftGap > 0, bottomGap > 0 {
                let corner = self.cropped(to: CGRect(x: bounds.minX, y: bounds.maxY - 1, width: 1, height: 1))
                corner.draw(in: CGRect(x: 0, y: rect.height - bottomGap, width: leftGap, height: bottomGap))
            }
            if rightGap > 0, bottomGap > 0 {
                let corner = self.cropped(to: CGRect(x: bounds.maxX - 1, y: bounds.maxY - 1, width: 1, height: 1))
                corner.draw(in: CGRect(x: rect.width - rightGap, y: rect.height - bottomGap, width: rightGap, height: bottomGap))
            }
        }
    }
}
