import SwiftUI
import Charts
import ModelDeckCore

enum DeckTheme {
    static let mint = Color(red: 0.40, green: 0.88, blue: 0.72)
    static let blue = Color(red: 0.46, green: 0.68, blue: 0.99)
    static let purple = Color(red: 0.70, green: 0.57, blue: 0.96)
    static let amber = Color(red: 0.96, green: 0.72, blue: 0.38)
    static let background = Color(red: 0.055, green: 0.071, blue: 0.085)
    static let card = Color(red: 0.085, green: 0.105, blue: 0.121)
    static let muted = Color(red: 0.55, green: 0.60, blue: 0.63)
    static func usage(_ value: Double) -> Color { value >= 90 ? .red : value >= 70 ? amber : mint }
}

struct DeckCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(DeckTheme.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.065), lineWidth: 1))
    }
}

struct SectionLabel: View {
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(1.8)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 11)).tracking(0) }
        }.foregroundStyle(DeckTheme.muted)
    }
}

struct StatusPill: View {
    let text: String
    var color = DeckTheme.mint
    var body: some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 5, height: 5); Text(text).font(.system(size: 10, weight: .medium)) }
            .foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 5)
            .background(color.opacity(0.10), in: Capsule())
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { item in
            AreaMark(x: .value("Campione", item.offset), y: .value("Percentuale", item.element))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.24), color.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Campione", item.offset), y: .value("Percentuale", item.element)).foregroundStyle(color).lineStyle(.init(lineWidth: 1.6)).interpolationMethod(.monotone)
        }.chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: 0...100).frame(height: 48)
            .accessibilityLabel("Storico, ultimi \(values.count) campioni")
    }
}

struct MetricCard: View {
    let title: String, symbol: String, value: String, detail: String
    let color: Color
    var history: [Double] = []
    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Image(systemName: symbol).foregroundStyle(color); Text(title).foregroundStyle(DeckTheme.muted); Spacer() }.font(.system(size: 11, weight: .medium))
                Text(value).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit().tracking(-1)
                Sparkline(values: history, color: color)
                Text(detail).font(.system(size: 10)).foregroundStyle(DeckTheme.muted).lineLimit(2).frame(height: 26, alignment: .topLeading)
            }
        }
    }
}

struct UsageCard: View {
    let usage: SubscriptionUsage
    var compact = false
    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: compact ? 12 : 18) {
                HStack(spacing: 10) {
                    Image(systemName: usage.provider == "Claude" ? "asterisk" : "circle.hexagongrid")
                        .font(.system(size: 19, weight: .medium)).foregroundStyle(usage.provider == "Claude" ? DeckTheme.amber : DeckTheme.mint)
                        .frame(width: 34, height: 34).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(usage.provider).font(.system(size: 15, weight: .semibold))
                        Text(usage.provider == "Claude" ? "Claude Code" : "Codex" + (usage.plan.map { " · " + $0.capitalized } ?? ""))
                            .font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                    }
                    Spacer()
                    if !usage.windows.isEmpty { StatusPill(text: usage.stale || usage.message != nil ? "Da aggiornare" : "Collegato", color: usage.stale || usage.message != nil ? DeckTheme.amber : DeckTheme.mint) }
                }
                if usage.windows.isEmpty {
                    Text(usage.message ?? "Quote non disponibili").font(.system(size: 12)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: compact ? 30 : 87, alignment: .topLeading)
                } else {
                    ForEach(usage.windows) { window in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(window.title).font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                                Spacer()
                                Text(window.isExpired ? "Da aggiornare" : "\(DeckFormat.percent(window.usedPercent)) usato")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(window.isExpired ? DeckTheme.muted : .white)
                            }
                            GeometryReader { geo in
                                Capsule().fill(.white.opacity(0.07))
                                Capsule().fill(window.isExpired ? DeckTheme.muted : DeckTheme.usage(window.usedPercent)).frame(width: geo.size.width * min(100, max(0, window.usedPercent)) / 100)
                            }.frame(height: 5)
                            if let reset = window.resetsAt {
                                HStack(spacing: 3) {
                                    Text(window.isExpired ? "Reset passato · attendi nuovi dati" : "Reset")
                                    if !window.isExpired { Text(reset, style: .relative) }
                                }.font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                                .help(reset.formatted(date: .complete, time: .shortened))
                            }
                        }
                    }
                    if let message = usage.message { Text(message).font(.system(size: 10)).foregroundStyle(DeckTheme.amber).fixedSize(horizontal: false, vertical: true) }
                }
                if !compact {
                    HStack(spacing: 4) {
                        Text(usage.source)
                        Spacer(minLength: 0)
                        if let date = usage.updatedAt { Text(date, style: .time).monospacedDigit() }
                    }.font(.system(size: 9)).foregroundStyle(DeckTheme.muted)
                }
            }
        }.frame(maxHeight: .infinity, alignment: .top)
    }
}
