import UIKit

extension UIImage {
    /// Crops a `rect`-sized region out of this image, where `rect` uses
    /// ordinary top-left-origin, y-down pixel coordinates (i.e. row 0 is the
    /// top row) — the same convention `ImageTiler` plans in. `rect` may
    /// extend past this image's bounds (e.g. the last tile in a row/column);
    /// anything outside the source image comes back transparent rather than
    /// edge-replicated. That only ever affects the discarded overlap margin
    /// of edge tiles (see `ImageTiler`), not the pixels that end up in the
    /// final stitched image, so it's a deliberate simplification rather than
    /// a bug — replace with true edge-mirroring if border artifacts show up
    /// with a particular model.
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
}
