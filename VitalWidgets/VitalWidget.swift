import SwiftUI
import WidgetKit

// Home-screen and lock-screen glance. Reads the snapshot the app publishes into the App Group; never
// computes anything itself, so it can never disagree with the app.

struct VitalEntry: TimelineEntry {
    let date: Date
    let snap: VitalSnapshot?
}

struct VitalProvider: TimelineProvider {
    func placeholder(in context: Context) -> VitalEntry {
        VitalEntry(date: Date(), snap: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (VitalEntry) -> Void) {
        completion(VitalEntry(date: Date(), snap: context.isPreview ? .placeholder : VitalSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VitalEntry>) -> Void) {
        // The app pushes reloads when data changes; this schedule only keeps "updated … ago" honest.
        let entry = VitalEntry(date: Date(), snap: VitalSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct VitalWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VitalGlance", provider: VitalProvider()) { entry in
            VitalWidgetView(entry: entry)
                .containerBackground(for: .widget) { VColor.canvas }
        }
        .configurationDisplayName("Vital")
        .description("Recovery, strain and sleep at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct VitalWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: VitalEntry

    private var s: VitalSnapshot? { entry.snap }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .systemMedium: medium
        default: small
        }
    }

    // MARK: Home screen

    /// Three rings and the date line, nothing else. Recovery and sleep as whole numbers, strain to tenths.
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                ring("Recovery", whole(s?.recovery), s?.recovery.map { $0 / 100 }, VColor.recovery(s?.recovery), size: 46)
                ring("Strain", strainText, s?.strain.map { min(1, $0 / 100) }, VColor.strain, size: 46)
                ring("Sleep", whole(s?.rest), s?.rest.map { $0 / 100 }, VColor.sleep, size: 46)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            HStack {
                footer
                if let bpm = s?.bpm, s?.connected == true {
                    HStack(spacing: 2) {
                        Image(systemName: "heart.fill").font(.system(size: 8))
                        Text("\(bpm)").font(.system(size: 9, weight: .semibold)).monospacedDigit()
                    }
                    .foregroundStyle(VColor.heart).fixedSize()
                }
            }
        }
    }

    private var medium: some View {
        HStack(spacing: 14) {
            ring("Recovery", whole(s?.recovery), s?.recovery.map { $0 / 100 }, VColor.recovery(s?.recovery))
            ring("Strain", strainText, s?.strain.map { min(1, $0 / 100) }, VColor.strain)
            ring("Sleep", whole(s?.rest), s?.rest.map { $0 / 100 }, VColor.sleep)
            VStack(alignment: .leading, spacing: 5) {
                line("HRV", tenths(s?.hrv) + " ms", VColor.hrv)
                line("RHR", s?.restingHr.map { "\($0) bpm" } ?? "--", VColor.rhr)
                if let bpm = s?.bpm, s?.connected == true {
                    line("Live", "\(bpm) bpm", VColor.heart)
                } else if let b = s?.batteryPct {
                    line("Strap", "\(b)%", VColor.textSecondary)
                }
                Spacer(minLength: 0)
                footer
            }
            .frame(minWidth: 96, maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Lock screen

    private var circular: some View {
        Gauge(value: s?.recovery ?? 0, in: 0...100) {
            Image(systemName: "heart.fill")
        } currentValueLabel: {
            Text(s?.recovery.map { "\(Int($0.rounded()))" } ?? "--").font(.system(.body, design: .rounded).weight(.semibold))
        }
        .gaugeStyle(.accessoryCircular)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill").font(.caption2)
                Text("Vital").font(.caption.weight(.semibold))
            }
            Text("Recovery \(whole(s?.recovery))%  ·  Strain \(strainText)")
                .font(.caption2).monospacedDigit()
            Text("Sleep \(whole(s?.rest))%  ·  HRV \(tenths(s?.hrv))  ·  RHR \(s?.restingHr.map(String.init) ?? "--")")
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    // MARK: Pieces

    private func tenths(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "--" }
    private func whole(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))" } ?? "--" }

    private var strainText: String { tenths(s?.strain.map { $0 * 21 / 100 }) }

    private func ring(_ title: String, _ value: String, _ progress: Double?, _ tint: Color, size: CGFloat = 58) -> some View {
        VStack(spacing: 3) {
            ZStack {
                VRing(progress: progress, tint: tint, lineWidth: size < 50 ? 4.5 : 6)
                Text(value)
                    .font(.system(size: size * 0.26, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.horizontal, size * 0.16)
            }
            .frame(width: size, height: size)
            Text(title.uppercased()).font(.system(size: size < 50 ? 7.5 : 9, weight: .semibold)).tracking(0.5)
                .foregroundStyle(VColor.textSecondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private func stat(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Circle().fill(tint).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 2.5 }
            Text(label).font(.system(size: 9)).foregroundStyle(VColor.textSecondary).lineLimit(1).fixedSize()
            Text(value).font(.system(size: 10, weight: .semibold)).monospacedDigit().lineLimit(1).fixedSize()
        }
    }

    /// One label/value row. The value never truncates: it takes layout priority and the label yields.
    private func line(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Circle().fill(tint).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
            Text(label).font(.caption2).foregroundStyle(VColor.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 40, alignment: .leading)
            Spacer(minLength: 3)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit()
                .lineLimit(1).fixedSize(horizontal: true, vertical: false).layoutPriority(1)
        }
    }

    private var footer: some View {
        Text(footerText).font(.system(size: 9)).foregroundStyle(VColor.textTertiary)
            .lineLimit(1).minimumScaleFactor(0.85).frame(maxWidth: .infinity, alignment: .leading)
    }


    private var footerText: String {
        guard let s, s.updated != .distantPast else { return "Open Vital to sync" }
        let mins = Int(Date().timeIntervalSince(s.updated) / 60)
        let when = mins < 1 ? "just now" : (mins < 60 ? "\(mins) min ago" : "\(mins / 60) h ago")
        if let day = s.dayKey { return "\(VFormat.dayLabel(day)) · \(when)" }
        return "Updated \(when)"
    }
}
