import SwiftUI
import WhoopStore

/// Flat list of every metric with its latest value, grouped by family. Reached from the row card at the
/// bottom of Today. Anything a tab does not surface (battery, steps, heart rate history) is reachable here.
struct BrowseScreen: View {
    @EnvironmentObject private var model: VitalModel
    @State private var seriesValues: [MetricID: Double] = [:]

    private struct Family: Identifiable {
        let name: String
        let ids: [MetricID]
        var id: String { name }
    }

    private let families: [Family] = [
        Family(name: "Scores", ids: [.recovery, .strain, .sleepPerformance]),
        Family(name: "Vitals", ids: [.hrv, .rhr, .hr, .respRate, .spo2, .skinTemp]),
        Family(name: "Sleep", ids: [.sleepHours]),
        Family(name: "Activity", ids: [.steps, .activeKcal]),
        Family(name: "Strap", ids: [.battery]),
    ]

    private var anchor: DailyMetric? { model.derived.anchor }

    var body: some View {
        VScreen(title: "Browse") {
            if let a = anchor {
                Text("Values are for \(VFormat.dayLabel(a.day)), the latest scored day.")
                    .font(.caption).foregroundStyle(VColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(families) { family in
                VSectionTitle(text: family.name)
                VCard(padding: VSpace.md) {
                    VStack(spacing: 0) {
                        ForEach(family.ids) { id in
                            row(id)
                            if id != family.ids.last { Divider().overlay(VColor.hairline) }
                        }
                    }
                }
            }
        }
        .toolbar { SettingsToolbarButton() }
        .task(id: "\(anchor?.day ?? "")|\(model.metricCache.version)") {
            guard let day = anchor?.day else { return }
            for id in MetricID.allCases {
                let m = VMetric.descriptor(id)
                if case .series? = m.dailyKey, let v = await model.seriesValue(m, day: day) { seriesValues[id] = v }
            }
        }
    }

    private func value(_ m: VMetric) -> Double? {
        if m.id == .battery { return model.live.batteryPct }
        return m.tileValue(anchor: anchor, seriesValue: seriesValues[m.id])
    }

    private func row(_ id: MetricID) -> some View {
        let m = VMetric.descriptor(id)
        let v = value(m)
        return MetricLink(id: id, dayKey: anchor?.day) {
            HStack(spacing: VSpace.md) {
                Image(systemName: m.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(m.tint)
                    .frame(width: VSpace.xxl, height: VSpace.xxl)
                    // Concentric with the card: 22 − 12 padding = 10.
                    .background(m.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: VSpace.cardRadius - VSpace.md, style: .continuous))
                Text(m.title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(m.unit.format(v)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(v == nil ? VColor.textTertiary : m.color(for: v))
                if !m.unit.label.isEmpty { Text(m.unit.label).font(VFont.caption).foregroundStyle(VColor.textTertiary) }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(VColor.textTertiary)
            }
            .frame(minHeight: VSpace.rowMinHeight)
            .contentShape(Rectangle())
        }
    }
}

/// Full-width row card that pushes Browse; same shape as Sleep's "All nights" link.
struct BrowseLinkCard: View {
    var body: some View {
        NavigationLink { BrowseScreen() } label: {
            HStack {
                Image(systemName: "square.grid.2x2").foregroundStyle(VColor.hrv)
                Text("All metrics").font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(VColor.textTertiary)
            }
            .padding(VSpace.lg)
            .background(VColor.surface, in: RoundedRectangle(cornerRadius: VSpace.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VSpace.cardRadius, style: .continuous).strokeBorder(VColor.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.vPress)
        .accessibilityHint("Lists every metric with its latest value")
    }
}
