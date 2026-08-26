import SwiftUI
import WidgetKit

struct CPUSmallWidget: Widget {
    var body: some WidgetConfiguration {
        moniWidgetConfiguration(
            kind: .cpuSmall,
            displayName: "CPU",
            description: "查看处理器总负载、用户态与系统态占比。",
            family: .systemSmall
        )
    }
}

struct CPUSmallWidgetView: View {
    let snapshot: WidgetSystemSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(
                title: "CPU",
                symbol: "cpu",
                color: WidgetTheme.pink,
                trailing: "\(snapshot.cpu.perCore.count) cores"
            )
            Text("\(Int(snapshot.cpu.total.rounded()))%")
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.75)
                .lineLimit(1)
                .padding(.top, 8)
            Text("\(Int(snapshot.cpu.user.rounded()))% user · \(Int(snapshot.cpu.system.rounded()))% sys")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(WidgetTheme.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 8)
            WidgetBars(values: snapshot.cpu.perCore, color: WidgetTheme.orange)
                .frame(height: 39)
        }
        .padding(16)
    }
}
