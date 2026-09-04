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

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("RECOVERY").font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(VColor.textSecondary)
                Spacer(minLength: 4)
                if let bpm = s?.bpm, s?.connected == true {
                    HStack(spacing: 2) {
                        Image(systemName: "heart.fill").font(.system(size: 9))
                        Text("\(bpm)").font(.caption2.weight(.semibold)).monospacedDigit()
                    }
                    .foregroundStyle(VColor.heart)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            HStack(alignment: .center, spacing: 8) {
                ZStack {
                    VRing(progress: s?.recovery.map { Double($0) / 100 },
                          tint: VColor.recovery(s?.recovery.map(Double.init)), lineWidth: 7)
                    Text(s?.recovery.map(String.init) ?? "--")
                        .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.7).lineLimit(1)
                }
                .frame(width: 62, height: 62)
                VStack(alignment: .leading, spacing: 3) {
                    line("Strain", strainText, VColor.strain)
                    line("Sleep", s?.rest.map { "\($0)%" } ?? "--", VColor.sleep)
                    line("HRV", s?.hrv.map { "\($0)" } ?? "--", VColor.hrv)
                }
                .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 4)
            footer
        }
    }

    private var medium: some View {
        HStack(spacing: 14) {
            ring("Recovery", s?.recovery.map(String.init) ?? "--", s?.recovery.map { Double($0) / 100 },
                 VColor.recovery(s?.recovery.map(Double.init)))
            ring("Strain", strainText, s?.strain.map { min(1, Double($0) / 100) }, VColor.strain)
            ring("Sleep", s?.rest.map(String.init) ?? "--", s?.rest.map { Double($0) / 100 }, VColor.sleep)
            VStack(alignment: .leading, spacing: 5) {
                line("HRV", s?.hrv.map { "\($0) ms" } ?? "--", VColor.hrv)
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
        Gauge(value: Double(s?.recovery ?? 0), in: 0...100) {
            Image(systemName: "heart.fill")
        } currentValueLabel: {
            Text(s?.recovery.map(String.init) ?? "--").font(.system(.body, design: .rounded).weight(.semibold))
        }
        .gaugeStyle(.accessoryCircular)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill").font(.caption2)
                Text("Vital").font(.caption.weight(.semibold))
            }
            Text("Recovery \(s?.recovery.map(String.init) ?? "--")%  ·  Strain \(strainText)")
                .font(.caption2).monospacedDigit()
            Text("HRV \(s?.hrv.map(String.init) ?? "--") ms  ·  RHR \(s?.restingHr.map(String.init) ?? "--")")
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    // MARK: Pieces

    private var strainText: String {
        s?.strain.map { String(format: "%.1f", Double($0) * 21 / 100) } ?? "--"
    }

    private func ring(_ title: String, _ value: String, _ progress: Double?, _ tint: Color) -> some View {
        VStack(spacing: 4) {
            ZStack {
                VRing(progress: progress, tint: tint, lineWidth: 6)
                Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 58, height: 58)
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.6)
                .foregroundStyle(VColor.textSecondary).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private func line(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Circle().fill(tint).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
            Text(label).font(.caption2).foregroundStyle(VColor.textSecondary).lineLimit(1)
                .frame(width: 40, alignment: .leading)
            Spacer(minLength: 2)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .trailing)
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
