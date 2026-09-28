import Charts
import SwiftUI

extension Format {
    private static let usd = Locale(identifier: "en_US")

    /// "$0.42", "$103.62", "$4,597".
    static func dollars(_ value: Double) -> String {
        let digits = value >= 1000 ? 0 : 2
        return value.formatted(.currency(code: "USD").locale(usd).precision(.fractionLength(digits)))
    }

    static func resets(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "resetting" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "resets in \(minutes)m" }
        if minutes < 24 * 60 { return "resets in \(minutes / 60)h \(minutes % 60)m" }
        return "resets " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

private func limitTint(_ limit: PlanLimit) -> Color {
    if limit.severity != "normal" || limit.percent >= 90 { return .red }
    if limit.percent >= 70 { return .orange }
    return .accentColor
}

// MARK: - Card on the Claude tab

struct UsageCard: View {
    @Environment(Store.self) private var store
    let usage: ClaudeUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text("Plan usage").font(.system(size: 11, weight: .semibold))
                if let plan = usage.plan {
                    Text(plan)
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: .capsule)
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                if store.isPending("usage") {
                    ProgressView().controlSize(.mini)
                } else {
                    IconButton(symbol: "arrow.clockwise", help: "Refresh usage", size: 18) { store.refreshUsage(force: true) }
                }
            }

            if usage.limits.isEmpty {
                Text(usage.error ?? "No plan limits reported")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(usage.limits.filter { $0.percent > 0 || $0.group == "session" || $0.label.hasPrefix("Weekly, all") }) {
                    LimitRow(limit: $0)
                }
            }

            Divider().opacity(0.6)

            HStack(alignment: .firstTextBaseline) {
                CostColumn(label: "today", value: usage.periods.today.cost)
                CostColumn(label: "7 days", value: usage.periods.week.cost)
                CostColumn(label: "30 days", value: usage.periods.month.cost)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Text("API-equivalent cost at list prices")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .card(radius: 10, padding: 10)
        .contentShape(.rect)
        .onTapGesture { store.push(.usage) }
    }
}

private struct CostColumn: View {
    let label: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Format.dollars(value))
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LimitRow: View {
    let limit: PlanLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.label).font(.system(size: 11, weight: .medium))
                Spacer()
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(Format.resets(limit.resetDate, now: context.date))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(limitTint(limit))
                    .frame(minWidth: 32, alignment: .trailing)
            }
            MeterBar(value: limit.percent / 100, tint: limitTint(limit), height: 5)
        }
    }
}

// MARK: - Detail page

struct UsageView: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            SubPageHeader(title: "Claude usage", subtitle: "Plan limits and API-equivalent cost") {
                if store.isPending("usage") {
                    ProgressView().controlSize(.small).frame(width: 24)
                } else {
                    IconButton(symbol: "arrow.clockwise", help: "Refresh") { store.refreshUsage(force: true) }
                }
            }
            Divider().opacity(0.5)
            if let usage = store.usage {
                ScrollView {
                    UsageBody(usage: usage).padding(12)
                }
                .scrollIndicators(.never)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { store.refreshUsage() }
            }
        }
    }
}

private struct UsageBody: View {
    let usage: ClaudeUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            limits
            periods
            dailyChart
            if !usage.models.isEmpty { modelBreakdown }
            if !usage.projects.isEmpty {
                RankedBars(title: "By project, 30 days", items: usage.projects, format: Format.dollars)
            }
            tokenMix
            footnote
        }
    }

    @ViewBuilder
    private var limits: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Plan limits").font(.system(size: 11, weight: .semibold))
                Spacer()
                if let plan = usage.plan {
                    Text(plan).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            if usage.limits.isEmpty {
                Text(usage.error ?? "No plan limits reported").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(usage.limits) { LimitRow(limit: $0) }
            }
            if let session = usage.session {
                Text("This session so far: \(Format.dollars(session.cost)) across \(session.requests) requests")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            if let extra = usage.extraUsage, let used = extra.used {
                Text("Extra usage: \(Format.dollars(used))" + (extra.limit.map { " of \(Format.dollars($0))" } ?? ""))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var periods: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            PeriodTile(label: "Today", totals: usage.periods.today)
            PeriodTile(label: "Last 7 days", totals: usage.periods.week)
            PeriodTile(label: "Last 30 days", totals: usage.periods.month)
            PeriodTile(label: "All time", totals: usage.periods.all)
        }
    }

    private var dailyChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Daily cost, 30 days").font(.system(size: 11, weight: .semibold))
            Chart(usage.daily, id: \.label) { day in
                BarMark(x: .value("Date", day.label), y: .value("Cost", day.value))
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(1.5)
            }
            .chartXAxis {
                AxisMarks(values: stride(from: 3, to: usage.daily.count, by: 7).map { usage.daily[$0].label }) { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) { Text(String(label.suffix(5))) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) { Text(Format.dollars(amount).replacingOccurrences(of: ".00", with: "")) }
                    }
                }
            }
            .font(.system(size: 9))
            .frame(height: 110)
        }
        .card()
    }

    private var modelBreakdown: some View {
        let maxCost = usage.models.map(\.cost).max() ?? 1
        return VStack(alignment: .leading, spacing: 7) {
            Text("By model, 30 days").font(.system(size: 11, weight: .semibold))
            ForEach(usage.models) { model in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(model.displayName).font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(Format.dollars(model.cost)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    MeterBar(value: maxCost > 0 ? model.cost / maxCost : 0, tint: .accentColor, height: 4)
                    Text("\(Format.count(model.requests)) requests · \(Format.count(model.input + model.cacheWrite + model.cacheRead)) in · \(Format.count(model.output)) out")
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .card()
    }

    private var tokenMix: some View {
        let month = usage.periods.month
        let rows: [(String, Int, Color)] = [
            ("Cache reads", month.cacheRead, .teal),
            ("Cache writes", month.cacheWrite, .indigo),
            ("Output", month.output, .orange),
            ("Uncached input", month.input, .pink),
        ]
        let total = max(month.tokens, 1)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Tokens, 30 days").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(Format.count(month.tokens)).font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(rows, id: \.0) { row in
                        Rectangle()
                            .fill(row.2.gradient)
                            .frame(width: max(2, geo.size.width * CGFloat(row.1) / CGFloat(total)))
                    }
                }
                .clipShape(.capsule)
            }
            .frame(height: 7)
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 6) {
                    Circle().fill(row.2).frame(width: 6, height: 6)
                    Text(row.0).font(.system(size: 10.5))
                    Spacer()
                    Text(Format.count(row.1)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .card()
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Costs use Anthropic API list prices (input, output, 5m/1h cache writes, cache reads, fast mode, web search) applied to the token counts in your local Claude Code transcripts. Your subscription is billed separately.")
            if !usage.unpricedModels.isEmpty {
                Text("No price known for: \(usage.unpricedModels.joined(separator: ", "))")
                    .foregroundStyle(.orange)
            }
            Text("Limits updated \(Date(timeIntervalSince1970: usage.limitsUpdated).formatted(date: .omitted, time: .shortened))")
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
    }
}

private struct PeriodTile: View {
    let label: String
    let totals: UsageTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Format.dollars(totals.cost))
                .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
            Text(label).font(.system(size: 10, weight: .medium))
            Text("\(Format.count(totals.tokens)) tokens · \(Format.count(totals.requests)) req")
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 8, padding: 9)
    }
}
