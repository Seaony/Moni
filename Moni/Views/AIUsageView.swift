import SwiftUI

struct AIUsageView: View {
    @EnvironmentObject private var store: AIUsageStore
    @AppStorage(PreferenceKey.aiUsageRangeDays) private var rangeDays = 30

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                DetailPanel("AI usage · last \(rangeDays) days") {
                    HStack(alignment: .bottom, spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tokens(store.summary.totalTokens))
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .moniNumericTransition(store.summary.totalTokens)
                            Text("tokens · \(store.summary.requestCount.formatted()) requests")
                                .foregroundStyle(.secondary)
                                .moniNumericTransition(store.summary.requestCount)
                        }
                        if let cost = store.summary.estimatedCostUSD {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(currency(cost))
                                    .font(.system(size: 24, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .moniNumericTransition(cost)
                                Text("estimated API cost")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        DailyUsageChart(values: store.summary.daily)
                            .frame(height: 120)
                    }
                    HStack {
                        Text("Local logs only. Costs use public API rates and are estimates, not subscription charges.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if store.isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .transition(MoniMotion.itemTransition)
                        }
                        Button("Refresh") { store.refresh(days: rangeDays) }
                            .disabled(store.isLoading)
                    }
                }

                if store.summary.providers.isEmpty && !store.isLoading {
                    DetailPanel("No local usage") {
                        Text("No Codex or Claude token usage was found in the last \(rangeDays) days.")
                            .foregroundStyle(.secondary)
                    }
                    .transition(MoniMotion.itemTransition)
                }

                ForEach(store.summary.providers) { provider in
                    providerPanel(provider)
                        .transition(MoniMotion.itemTransition)
                }
            }
            .moniAnimation(value: store.isLoading)
            .moniAnimation(value: store.summary.providers.map(\.id))
        }
        .task {
            store.loadIfNeeded(days: rangeDays)
        }
    }

    private func providerPanel(_ provider: AIProviderUsage) -> some View {
        DetailPanel(provider.provider) {
            HStack(alignment: .firstTextBaseline) {
                Text(tokens(provider.totalTokens))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(provider.provider == "Codex" ? .blue : .orange)
                    .moniNumericTransition(provider.totalTokens)
                Text("tokens")
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let cost = provider.estimatedCostUSD {
                        Text(currency(cost))
                            .fontWeight(.semibold)
                            .moniNumericTransition(cost)
                    }
                    Text("\(provider.requestCount) requests · \(provider.sessionCount) sessions")
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                stat("Non-cached input", provider.inputTokens, .blue)
                stat("Output", provider.outputTokens, .green)
                stat("Cache read", provider.cacheReadTokens, .cyan)
                stat("Cache write", provider.cacheWriteTokens, .teal)
                stat("Reasoning", provider.reasoningTokens, .purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cache hit").foregroundStyle(.secondary)
                    Text(provider.cacheHitPercent.map { "\(String(format: "%.1f", $0))%" } ?? "—")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .moniNumericTransition(provider.cacheHitPercent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Label(provider.models.first?.model ?? "Model unavailable", systemImage: "brain")
                Spacer()
                if provider.unpricedRequestCount > 0 {
                    Text("\(provider.unpricedRequestCount) unpriced")
                        .foregroundStyle(.orange)
                }
                if let lastUpdated = provider.lastUpdated {
                    Text("Updated \(lastUpdated.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            if !provider.models.isEmpty {
                Divider()
                ForEach(provider.models.prefix(6)) { model in
                    HStack(spacing: 12) {
                        Text(model.model)
                            .lineLimit(1)
                        Spacer()
                        Text("\(model.requestCount) req")
                            .foregroundStyle(.secondary)
                        Text(tokens(model.totalTokens))
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                        Text(model.estimatedCostUSD.map(currency) ?? "—")
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }
                    .font(.caption)
                    .transition(MoniMotion.itemTransition)
                }
            }
        }
        .moniAnimation(value: provider.models.map(\.id))
    }

    private func stat(_ title: String, _ value: UInt64, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).foregroundStyle(.secondary)
            }
            Text(tokens(value))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .moniNumericTransition(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tokens(_ value: UInt64) -> String {
        value.formatted(.number.notation(.compactName))
    }

    private func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value < 0.01 ? 4 : 2)))
    }
}

struct DailyUsageChart: View {
    let values: [DailyAIUsage]

    var body: some View {
        GeometryReader { geometry in
            let recent = Array(values.suffix(14))
            let maximum = max(1, recent.map(\.tokens).max() ?? 1)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(recent) { day in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.indigo.gradient)
                        .frame(height: max(3, geometry.size.height * CGFloat(Double(day.tokens) / Double(maximum))))
                        .help(
                            "\(day.date.formatted(date: .abbreviated, time: .omitted)): "
                                + "\(day.tokens.formatted()) tokens · \(day.requestCount) requests · "
                                + day.costUSD.formatted(
                                    .currency(code: "USD")
                                        .precision(.fractionLength(day.costUSD < 0.01 ? 4 : 2))
                                )
                        )
                }
            }
            .moniAnimation(MoniMotion.data, value: recent.map(\.tokens))
        }
        .accessibilityLabel("Daily token usage for the last fourteen calendar days")
    }
}
