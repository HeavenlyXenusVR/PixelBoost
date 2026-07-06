import CoreGraphics

/// Splits a large image into fixed-size, overlapping tiles so a Core ML model
/// with a small fixed input size (e.g. 128x128) can upscale an arbitrarily
/// large photo one tile at a time. Neighboring tiles overlap by `overlap`
/// pixels on each side so the model sees context beyond the region it's
/// actually responsible for — otherwise every tile's edges would look
/// noticeably worse than its center, since most CNN-based super-resolution
/// models rely on a receptive field that extends past the output pixel
/// itself. Only the non-overlapping "core" of each tile's output is kept;
/// this is the same pad-then-crop scheme Real-ESRGAN's own `--tile` CLI
/// option uses, which is simpler and just as effective as a feathered blend.
///
/// All coordinates are top-left-origin, y-down pixel coordinates, matching
/// `UIImage.cropped(to:)` and ordinary raster/array indexing — NOT Core
/// Image's bottom-left/y-up coordinate space.
struct ImageTiler {
    let tileSize: Int
    let overlap: Int
    let scaleFactor: Int

    struct Tile {
        /// Always exactly `tileSize` x `tileSize`; may extend past the
        /// source image's bounds near the right/bottom edges.
        let sourceRect: CGRect
        /// The core (non-context) sub-region of `sourceRect`, in
        /// tile-local coordinates. Always offset by `overlap` from the
        /// tile's origin; only its width/height shrink, on the last
        /// row/column where the image runs out before a full core box.
        let keepRect: CGRect
        /// Where `keepRect`, scaled by `scaleFactor`, lands in the final
        /// output canvas.
        let destOrigin: CGPoint
    }

    struct Plan {
        let tiles: [Tile]
        let outputSize: CGSize
    }

    /// - Precondition: `overlap` must be less than half of `tileSize`, or
    ///   there'd be no core region left for any tile to contribute.
    func plan(imageWidth: Int, imageHeight: Int) -> Plan {
        let core = tileSize - overlap * 2
        precondition(core > 0, "overlap must be less than half of tileSize")

        var tiles: [Tile] = []
        var y = 0
        while y < imageHeight {
            let coreHeight = min(core, imageHeight - y)
            var x = 0
            while x < imageWidth {
                let coreWidth = min(core, imageWidth - x)

                let sourceRect = CGRect(
                    x: CGFloat(x - overlap), y: CGFloat(y - overlap),
                    width: CGFloat(tileSize), height: CGFloat(tileSize)
                )
                let keepRect = CGRect(
                    x: CGFloat(overlap), y: CGFloat(overlap),
                    width: CGFloat(coreWidth), height: CGFloat(coreHeight)
                )
                let destOrigin = CGPoint(x: CGFloat(x * scaleFactor), y: CGFloat(y * scaleFactor))

                tiles.append(Tile(sourceRect: sourceRect, keepRect: keepRect, destOrigin: destOrigin))
                x += core
            }
            y += core
        }

        let outputSize = CGSize(width: CGFloat(imageWidth * scaleFactor), height: CGFloat(imageHeight * scaleFactor))
        return Plan(tiles: tiles, outputSize: outputSize)
    }
}
