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
        DockerSmallWidget()
        GPUSmallWidget()
        UptimeSmallWidget()
        NetworkMediumWidget()
        TopProcessesMediumWidget()
        SensorsMediumWidget()
        MemoryMediumWidget()
        DiskActivityMediumWidget()
        ContainersMediumWidget()
        AlertsMediumWidget()
        BatteryHistoryMediumWidget()
        SystemOverviewLargeWidget()
        GPUThermalsLargeWidget()
        NetworkDetailLargeWidget()
        ActivityMonitorLargeWidget()
        StorageBreakdownLargeWidget()
    }
}
