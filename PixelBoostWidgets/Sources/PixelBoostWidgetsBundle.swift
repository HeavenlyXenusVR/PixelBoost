import WidgetKit
import SwiftUI

@main
struct PixelBoostWidgetsBundle: WidgetBundle {
    var body: some Widget {
        UpscaleStatsWidget()
        BatchUpscaleLiveActivityWidget()
    }
}
