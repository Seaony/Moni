import SwiftUI
import WidgetKit

struct NetworkMediumWidget: Widget {
    var body: some WidgetConfiguration {
        moniWidgetConfiguration(
            kind: .networkMedium,
            displayName: "Network",
            description: "查看实时下载、上传速率与网络趋势。",
            family: .systemMedium
        )
    }
}

struct NetworkMediumWidgetView: View {
    let snapshot: WidgetSystemSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(
                title: "Network",
                symbol: "arrow.up.arrow.down",
                color: WidgetTheme.cyan,
                trailing: networkDetail
            )
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    rate("Download", symbol: "arrow.down", value: snapshot.network.downloadBytesPerSecond, color: WidgetTheme.cyan)
                    rate("Upload", symbol: "arrow.up", value: snapshot.network.uploadBytesPerSecond, color: WidgetTheme.orange)
                }
                .frame(width: 98, alignment: .leading)
                ZStack {
                    WidgetLineChart(values: snapshot.histories.download, color: WidgetTheme.cyan)
                    WidgetLineChart(values: snapshot.histories.upload, color: WidgetTheme.orange, showsFill: false)
                }
                .padding(.top, 8)
            }
            .padding(.top, 10)
        }
        .padding(16)
    }

    private var networkDetail: String {
        [snapshot.network.interfaceName, snapshot.network.physicalMode]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func rate(_ label: String, symbol: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(label, systemImage: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(color)
            Text(ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .decimal) + "/s")
                .font(.system(size: 21, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
    }
}
