import SwiftUI
import WidgetKit

@main
struct MoniWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CPUSmallWidget()
        MemorySmallWidget()
        PowerSmallWidget()
        StorageSmallWidget()
        WiFiSmallWidget()
        ProcessesSmallWidget()
        AISpendSmallWidget()
    }
}
