import SwiftUI

struct AIUsageView: View {
    @EnvironmentObject private var store: AIUsageStore
    @AppStorage(PreferenceKey.aiUsageRange) private var rangeValue = AIUsageRange.last30Days.rawValue
    @AppStorage(PreferenceKey.disabledAIProviders) private var disabledProviderValue = ""
    let onManageProviders: () -> Void

    private var range: AIUsageRange {
        AIUsageRange(rawValue: rangeValue) ?? .last30Days
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                rangePicker
                usagePanel

                if !visibleProviders.isEmpty {
                    VStack(spacing: 12) {
                        ForEach(Array(providerRows.enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(row) { provider in
                                    providerPanel(provider)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                        .transition(MoniMotion.itemTransition)
                                }

                                if row.count == 1 {
                                    Color.clear
                                        .frame(maxWidth: .infinity, maxHeight: 0)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
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
                            Button("Manage providers…", action: onManageProviders)
                                .font(.system(size: 12))
                                .foregroundStyle(MoniPalette.blue)
                                .buttonStyle(.plain)
                                .moniPointingHand()
                        }
                    }
                }
            }
            .moniAnimation(value: store.isLoading)
            .moniAnimation(value: visibleProviders.map(\.id))
        }
        .task {
            store.loadIfNeeded(
                range: range,
                includeQuotas: true,
                allowKeychainPrompt: true
            )
        }
        .onChange(of: rangeValue) { _, value in
            store.refresh(range: AIUsageRange(rawValue: value) ?? .last30Days, includeQuotas: true)
        }
    }

    private var visibleProviders: [AIProviderUsage] {
        let disabled = Set(disabledProviderValue.split(separator: ",").map(String.init))
        return store.summary.providers.filter { !disabled.contains($0.provider) }
    }

    private var providerRows: [[AIProviderUsage]] {
        stride(from: 0, to: visibleProviders.count, by: 2).map { start in
            Array(visibleProviders[start..<min(start + 2, visibleProviders.count)])
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

            DailyUsageChart(
                values: store.summary.daily,
                maximumDayCount: chartDayLimit
            )
                .frame(height: 92)

            HStack {
                Text(chartStartLabel)
                Spacer()
                Text("today")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.quaternary)

        }
    }

    private func providerPanel(_ provider: AIProviderUsage) -> some View {
        let quotaWindows = provider.quotaWindows.filter {
            !$0.label.localizedCaseInsensitiveContains("code review")
        }
        let quotaMessage = provider.quotaMessage.flatMap { message in
            message.localizedCaseInsensitiveContains("code review") ? nil : message
        }
        let weeklyQuota = quotaWindows.first(where: isWeeklyQuota)
        let weeklyLimit = weeklyQuota.flatMap {
            estimatedWeeklyLimitUSD(for: provider, quota: $0)
        }

        return DetailPanel {
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
                if provider.cacheWriteTokens > 0 || provider.reasoningTokens == 0 {
                    providerStat("Cache write", tokens(provider.cacheWriteTokens))
                }
                if provider.reasoningTokens > 0 {
                    providerStat("Reasoning", tokens(provider.reasoningTokens))
                }
            }

            if !quotaWindows.isEmpty {
                Divider()
                VStack(spacing: 12) {
                    ForEach(quotaWindows) { window in
                        quotaRow(window, color: providerColor(provider))
                    }
                }
            }
            if let message = quotaMessage {
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

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Text(quotaResetLabel(weeklyQuota))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help("Time remaining until this provider reports that the weekly quota resets.")
                Spacer()
                Text(weeklyLimit.map(weeklyLimitLabel) ?? "Estimating…")
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Estimated API-equivalent weekly limit from local usage and the provider-reported weekly percentage.")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(MoniPalette.inset)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .moniAnimation(value: quotaWindows.map(\.remainingPercent))
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

    private func quotaResetLabel(_ quota: AIQuotaWindow?) -> String {
        guard let quota else { return "Reset unavailable" }
        if let resetsAt = quota.resetsAt {
            return "resets in \(resetDuration(until: resetsAt))"
        }
        if let minutes = quota.windowMinutes {
            return "\(compactDuration(minutes: minutes)) window"
        }
        return "Reset unavailable"
    }

    private func isWeeklyQuota(_ quota: AIQuotaWindow) -> Bool {
        quota.windowMinutes == 10_080 || quota.label.localizedCaseInsensitiveContains("week")
    }

    private func estimatedWeeklyLimitUSD(
        for provider: AIProviderUsage,
        quota: AIQuotaWindow
    ) -> Double? {
        guard isWeeklyQuota(quota),
            quota.usedPercent >= 1,
            let windowCost = store.summary.weeklyWindowCostsUSD?[provider.provider],
            windowCost > 0
        else { return nil }

        let estimate = windowCost / (quota.usedPercent / 100)
        return estimate.isFinite && estimate > 0 ? estimate : nil
    }

    private func weeklyLimitLabel(_ value: Double) -> String {
        let amount = value.formatted(
            .number.grouping(.automatic).precision(.fractionLength(value < 100 ? 1 : 0))
        )
        return "≈ $\(amount) weekly"
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

    private var chartDayLimit: Int? {
        switch range {
        case .last30Days: 30
        case .last90Days: 90
        case .all: nil
        }
    }

    private var chartStartLabel: String {
        switch range {
        case .last30Days: "-30 d"
        case .last90Days: "-90 d"
        case .all:
            store.summary.daily.first?.date.formatted(
                .dateTime.year().month(.abbreviated).day()
            ) ?? "All"
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
        let detected = Set(visibleProviders.map(\.provider))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredDayID: DailyAIUsage.ID?

    let values: [DailyAIUsage]
    let maximumDayCount: Int?
    let tooltipAvoidsPointer: Bool

    init(
        values: [DailyAIUsage],
        maximumDayCount: Int? = 14,
        tooltipAvoidsPointer: Bool = false
    ) {
        self.values = values
        self.maximumDayCount = maximumDayCount
        self.tooltipAvoidsPointer = tooltipAvoidsPointer
    }

    var body: some View {
        GeometryReader { geometry in
            let recent = displayedValues
            let maximum = max(1, recent.map(\.tokens).max() ?? 1)
            let spacing = min(
                6,
                geometry.size.width / CGFloat(max(1, recent.count)) * 0.35
            )
            let barWidth = max(
                0.1,
                (geometry.size.width - spacing * CGFloat(max(0, recent.count - 1)))
                    / CGFloat(max(1, recent.count))
            )

            ZStack(alignment: .topLeading) {
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, day in
                        usageBar(
                            day,
                            isEmphasized: index == recent.count - 1,
                            maximum: maximum,
                            chartHeight: geometry.size.height,
                            width: barWidth
                        )
                    }
                }

                if let hoveredDay,
                   let hoveredIndex = recent.firstIndex(where: { $0.id == hoveredDay.id })
                {
                    usageTooltip(hoveredDay)
                        .fixedSize()
                        .position(
                            x: tooltipX(
                                index: hoveredIndex,
                                barWidth: barWidth,
                                spacing: spacing,
                                chartWidth: geometry.size.width
                            ),
                            y: tooltipY(
                                day: hoveredDay,
                                maximum: maximum,
                                chartHeight: geometry.size.height
                            )
                        )
                        .allowsHitTesting(false)
                        .transition(
                            reduceMotion
                                ? .identity
                                : .opacity.combined(with: .scale(scale: 0.96))
                        )
                        .zIndex(1)
                }
            }
            .moniAnimation(MoniMotion.data, value: recent.map(\.tokens))
        }
        .onDisappear {
            hoveredDayID = nil
        }
        .accessibilityLabel("Daily token usage")
    }

    private var displayedValues: [DailyAIUsage] {
        guard let maximumDayCount else { return values }
        return Array(values.suffix(maximumDayCount))
    }

    private var hoveredDay: DailyAIUsage? {
        displayedValues.first { $0.id == hoveredDayID }
    }

    private func usageBar(
        _ day: DailyAIUsage,
        isEmphasized: Bool,
        maximum: UInt64,
        chartHeight: CGFloat,
        width: CGFloat
    ) -> some View {
        let isHovered = hoveredDayID == day.id
        let barColor = isHovered
            ? MoniPalette.indigo
            : MoniPalette.indigo.opacity(isEmphasized ? 1 : 0.45)
        let barHeight = max(
            4,
            chartHeight * CGFloat(Double(day.tokens) / Double(maximum))
        )

        return ZStack(alignment: .bottom) {
            Color.clear
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(barColor)
                .frame(height: barHeight)
                .scaleEffect(x: isHovered ? 1.08 : 1, y: 1, anchor: .bottom)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { isHovering in
            let update = {
                hoveredDayID = isHovering ? day.id : nil
            }
            if reduceMotion {
                update()
            } else {
                withAnimation(MoniMotion.press) {
                    update()
                }
            }
        }
    }

    private func usageTooltip(_ day: DailyAIUsage) -> some View {
        let providers = providerBreakdown(for: day)

        return VStack(alignment: .leading, spacing: 3) {
            Text(day.date.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(MoniPalette.foregroundSecondary)
            Text("\(day.tokens.formatted(.number.notation(.compactName))) tokens")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(MoniPalette.foreground)
                .monospacedDigit()
            Text("≈\(currency(day.costUSD)) · \(day.requestCount.formatted()) requests")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            if !providers.isEmpty {
                Divider()
                    .padding(.vertical, 2)

                ForEach(providers, id: \.name) { provider in
                    HStack(spacing: 10) {
                        HStack(spacing: 5) {
                            providerIcon(provider.name)
                            Text(provider.name)
                                .foregroundStyle(MoniPalette.foregroundSecondary)
                        }
                        Spacer(minLength: 12)
                        Text(
                            "\(provider.usage.tokens.formatted(.number.notation(.compactName))) · "
                                + "≈ \(currency(provider.usage.costUSD))"
                        )
                        .fontWeight(.semibold)
                        .foregroundStyle(MoniPalette.foreground)
                        .monospacedDigit()
                    }
                    .font(.system(size: 10.5))
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(minWidth: 188)
        .background(MoniPalette.controlHover)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(MoniPalette.panelLine.opacity(0.42), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
    }

    private func providerBreakdown(
        for day: DailyAIUsage
    ) -> [(name: String, usage: DailyAIProviderUsage)] {
        (day.providers ?? [:])
            .filter { $0.value.tokens > 0 || $0.value.costUSD > 0 }
            .sorted { lhs, rhs in
                if lhs.value.tokens != rhs.value.tokens {
                    return lhs.value.tokens > rhs.value.tokens
                }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .map { (name: $0.key, usage: $0.value) }
    }

    @ViewBuilder
    private func providerIcon(_ provider: String) -> some View {
        if let iconName = providerIconName(provider) {
            Image(iconName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(providerColor(provider))
                .frame(width: 11, height: 11)
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(MoniPalette.foregroundSecondary)
                .frame(width: 11, height: 11)
        }
    }

    private func providerIconName(_ provider: String) -> String? {
        switch provider {
        case "Claude": "ProviderIcon-claude"
        case "Codex": "ProviderIcon-codex"
        case "Gemini CLI": "ProviderIcon-gemini"
        case "Qwen Code": "ProviderIcon-alibaba"
        case "Kimi Code": "ProviderIcon-kimi"
        case "DeepSeek Harness": "ProviderIcon-deepseek"
        case "OpenCode": "ProviderIcon-opencode"
        case "GitHub Copilot": "ProviderIcon-copilot"
        case "Grok": "ProviderIcon-grok"
        default: nil
        }
    }

    private func providerColor(_ provider: String) -> Color {
        switch provider {
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

    private func tooltipX(
        index: Int,
        barWidth: CGFloat,
        spacing: CGFloat,
        chartWidth: CGFloat
    ) -> CGFloat {
        let tooltipHalfWidth: CGFloat = 100
        let barCenter = CGFloat(index) * (barWidth + spacing) + barWidth / 2
        if tooltipAvoidsPointer {
            let pointerClearance: CGFloat = 14
            return barCenter + pointerClearance + tooltipHalfWidth
        }
        return min(
            max(barCenter, tooltipHalfWidth),
            max(tooltipHalfWidth, chartWidth - tooltipHalfWidth)
        )
    }

    private func tooltipY(
        day: DailyAIUsage,
        maximum: UInt64,
        chartHeight: CGFloat
    ) -> CGFloat {
        let barHeight = max(
            4,
            chartHeight * CGFloat(Double(day.tokens) / Double(maximum))
        )
        // Keep the callout inside the chart when the bar nearly fills it; 26 is
        // half the three-line callout's height.
        return max(26, chartHeight - barHeight - 34)
    }

    private func currency(_ value: Double) -> String {
        "$" + value.formatted(
            .number.precision(.fractionLength(value < 0.01 ? 4 : 2))
        )
    }
}
