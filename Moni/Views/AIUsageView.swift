import SwiftUI

struct AIUsageView: View {
    @EnvironmentObject private var store: AIUsageStore
    @AppStorage(PreferenceKey.aiUsageRange) private var rangeValue = AIUsageRange.month.rawValue
    let onAddSource: () -> Void

    private var range: AIUsageRange {
        AIUsageRange(rawValue: rangeValue) ?? .month
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                rangePicker
                usagePanel

                if !store.summary.providers.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
                        spacing: 12
                    ) {
                        ForEach(store.summary.providers) { provider in
                            providerPanel(provider)
                                .transition(MoniMotion.itemTransition)
                        }
                    }
                } else if !store.isLoading {
                    DetailPanel("No local usage") {
                        Text("No Codex or Claude Code token usage was found for \(range.title.lowercased()).")
                            .foregroundStyle(.secondary)
                    }
                    .transition(MoniMotion.itemTransition)
                }

                if !missingSources.isEmpty {
                    DetailPanel {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(MoniPalette.orange)
                            Text("No local logs found for: \(missingSources.joined(separator: " · "))")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button("Add source…", action: onAddSource)
                                .font(.system(size: 12))
                                .foregroundStyle(MoniPalette.blue)
                                .buttonStyle(.plain)
                                .moniPointingHand()
                        }
                    }
                }
            }
            .moniAnimation(value: store.isLoading)
            .moniAnimation(value: store.summary.providers.map(\.id))
        }
        .task {
            store.loadIfNeeded(range: range, includeQuotas: true)
        }
        .onChange(of: rangeValue) { _, value in
            store.refresh(range: AIUsageRange(rawValue: value) ?? .month, includeQuotas: true)
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 4) {
            ForEach(AIUsageRange.allCases) { item in
                Button {
                    rangeValue = item.rawValue
                } label: {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(range == item ? MoniPalette.foreground : MoniPalette.foregroundTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(range == item ? MoniPalette.controlSelected : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .moniPointingHand()
            }
        }
        .padding(4)
        .background(MoniPalette.control)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var usagePanel: some View {
        DetailPanel {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Usage & spend")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(MoniPalette.indigo)
                Text("\(range.title) · estimated at API list prices, not your invoice")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 12)
                Text(store.summary.estimatedCostUSD.map(currency) ?? "—")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                spacing: 12
            ) {
                totalStat("Spend", store.summary.estimatedCostUSD.map(currencyWithoutGrouping) ?? "—")
                totalStat("Tokens", tokens(store.summary.totalTokens))
                totalStat("Cache hit", store.summary.cacheHitPercent.map(percent) ?? "—")
                totalStat(
                    "Priced entries",
                    "\(store.summary.pricedRequestCount.formatted()) / \(store.summary.requestCount.formatted())"
                )
            }

            DailyUsageChart(values: store.summary.daily)
                .frame(height: 92)

            HStack {
                Text(chartStartLabel)
                Spacer()
                Text(range == .yesterday || range == .lastWeek ? range.title.lowercased() : "today")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.quaternary)

        }
    }

    private func providerPanel(_ provider: AIProviderUsage) -> some View {
        DetailPanel {
            HStack(spacing: 8) {
                Circle()
                    .fill(providerColor(provider))
                    .frame(width: 9, height: 9)
                Text(provider.provider == "Claude" ? "Claude Code" : provider.provider)
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Text(provider.planName ?? "Local logs")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(MoniPalette.control)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(tokens(provider.totalTokens))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .moniNumericTransition(provider.totalTokens)
                Text("tokens · \(provider.estimatedCostUSD.map(currency) ?? "unpriced")")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())],
                spacing: 12
            ) {
                providerStat("≈ Cost", provider.estimatedCostUSD.map(currency) ?? "—")
                providerStat("Cache hit", provider.cacheHitPercent.map(percent) ?? "—")
                providerStat("Input", tokens(provider.inputTokens))
                providerStat("Output", tokens(provider.outputTokens))
                providerStat("Cache read", tokens(provider.cacheReadTokens))
                if provider.reasoningTokens > 0 {
                    providerStat("Reasoning", tokens(provider.reasoningTokens))
                } else {
                    providerStat("Cache write", tokens(provider.cacheWriteTokens))
                }
            }

            if !provider.quotaWindows.isEmpty {
                Divider()
                VStack(spacing: 12) {
                    ForEach(provider.quotaWindows) { window in
                        quotaRow(window, color: providerColor(provider))
                    }
                }
            }
            if let message = provider.quotaMessage {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(MoniPalette.orange)
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 8) {
                Text("Top model")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(provider.models.first?.model ?? "Model unavailable")
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(MoniPalette.inset)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .moniAnimation(value: provider.quotaWindows.map(\.remainingPercent))
    }

    private func quotaRow(_ window: AIQuotaWindow, color: Color) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.label)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("\(Int(window.remainingPercent.rounded()))% left")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(color)
                    .monospacedDigit()
                if let resetsAt = window.resetsAt {
                    Text(resetDuration(until: resetsAt))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                } else if let minutes = window.windowMinutes {
                    Text(compactDuration(minutes: minutes))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(MoniPalette.track)
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(window.remainingPercent / 100))
                }
            }
            .frame(height: 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(window.label)
            .accessibilityValue("\(Int(window.remainingPercent.rounded())) percent remaining")
        }
    }

    private func compactDuration(minutes: Int) -> String {
        if minutes >= 1_440 { return "\(minutes / 1_440)d" }
        if minutes >= 60 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    private func totalStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MoniPalette.inset)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func providerStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.bold).monospacedDigit()
        }
        .font(.system(size: 12.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chartStartLabel: String {
        switch range {
        case .today: "00:00"
        case .year: "Jan"
        default: "-14 d"
        }
    }

    private func providerColor(_ provider: AIProviderUsage) -> Color {
        switch provider.provider {
        case "Codex": MoniPalette.cyan
        case "Claude": MoniPalette.claude
        case "Qwen Code": MoniPalette.purple
        case "Gemini CLI": MoniPalette.blue
        case "Kimi Code": MoniPalette.yellow
        case "DeepSeek Harness": MoniPalette.indigo
        case "OpenCode": MoniPalette.green
        default: MoniPalette.foregroundSecondary
        }
    }

    private var missingSources: [String] {
        let detected = Set(store.summary.providers.map(\.provider))
        return ["Gemini CLI", "Qwen Code", "Kimi Code", "DeepSeek Harness", "OpenCode"]
            .filter { !detected.contains($0) }
    }

    private func tokens(_ value: UInt64) -> String {
        value.formatted(.number.notation(.compactName))
    }

    private func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private func currency(_ value: Double) -> String {
        "$" + value.formatted(
            .number.grouping(.automatic).precision(.fractionLength(value < 0.01 ? 4 : 2))
        )
    }

    private func currencyWithoutGrouping(_ value: Double) -> String {
        "$" + value.formatted(
            .number.grouping(.never).precision(.fractionLength(value < 0.01 ? 4 : 2))
        )
    }

    private func resetDuration(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3_600
        let minutes = seconds % 3_600 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

struct DailyUsageChart: View {
    let values: [DailyAIUsage]

    var body: some View {
        GeometryReader { geometry in
            let recent = Array(values.suffix(14))
            let maximum = max(1, recent.map(\.tokens).max() ?? 1)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, day in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(MoniPalette.indigo.opacity(index == max(0, recent.count - 3) ? 1 : 0.45))
                        .frame(
                            height: max(
                                4,
                                geometry.size.height * CGFloat(Double(day.tokens) / Double(maximum))
                            )
                        )
                        .help(tooltip(for: day))
                }
            }
            .moniAnimation(MoniMotion.data, value: recent.map(\.tokens))
        }
        .accessibilityLabel("Daily token usage")
    }

    private func tooltip(for day: DailyAIUsage) -> String {
        let date = day.date.formatted(date: .abbreviated, time: .omitted)
        let cost = day.costUSD.formatted(
            .number.precision(.fractionLength(day.costUSD < 0.01 ? 4 : 2))
        )
        return "\(date): \(day.tokens.formatted()) tokens · \(day.requestCount) requests · $\(cost)"
    }
}
