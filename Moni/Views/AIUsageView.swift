import SwiftUI

struct AIUsageView: View {
    @EnvironmentObject private var store: AIUsageStore
    @AppStorage(PreferenceKey.aiUsageRangeDays) private var rangeDays = 30

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                DetailPanel("AI usage · last \(rangeDays) days") {
                    HStack(alignment: .bottom, spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tokens(store.summary.totalTokens))
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("tokens across \(store.summary.providers.reduce(0) { $0 + $1.sessionCount }) sessions")
                                .foregroundStyle(.secondary)
                        }
                        DailyUsageChart(values: store.summary.daily)
                            .frame(height: 120)
                    }
                    HStack {
                        Text("Usage is read from local Codex and Claude JSONL logs. Message content is not loaded into the UI.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if store.isLoading {
                            ProgressView().controlSize(.small)
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
                }

                ForEach(store.summary.providers) { provider in
                    providerPanel(provider)
                }
            }
        }
    }

    private func providerPanel(_ provider: AIProviderUsage) -> some View {
        DetailPanel(provider.provider) {
            HStack(alignment: .firstTextBaseline) {
                Text(tokens(provider.totalTokens))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(provider.provider == "Codex" ? .blue : .orange)
                Text("tokens")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(provider.sessionCount) sessions")
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                stat("Input", provider.inputTokens, .blue)
                stat("Output", provider.outputTokens, .green)
                stat("Cached", provider.cachedTokens, .cyan)
                stat("Reasoning", provider.reasoningTokens, .purple)
            }

            Divider()
            HStack {
                Label(provider.topModel ?? "Model unavailable", systemImage: "brain")
                Spacer()
                if let lastUpdated = provider.lastUpdated {
                    Text("Updated \(lastUpdated.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tokens(_ value: UInt64) -> String {
        value.formatted(.number.notation(.compactName))
    }
}

private struct DailyUsageChart: View {
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
                        .help("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.tokens.formatted()) tokens")
                }
            }
        }
        .accessibilityLabel("Daily token usage for the last fourteen active days")
    }
}
