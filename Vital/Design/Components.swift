import Charts
import SwiftUI

// Vital's component kit. Every screen composes these; none of them import StrandDesign.

// MARK: Card

struct VCard<Content: View>: View {
    var padding: CGFloat = VSpace.lg
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VColor.surface, in: RoundedRectangle(cornerRadius: VSpace.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VSpace.cardRadius, style: .continuous)
                .strokeBorder(VColor.hairline, lineWidth: 1))
    }
}

struct VCardHeader: View {
    let title: String
    var subtitle: String? = nil
    var tint: Color = VColor.textSecondary
    var systemImage: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: VSpace.sm) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(tint).font(.subheadline.weight(.semibold))
            }
            Text(title).font(VFont.cardTitle).foregroundStyle(VColor.textPrimary)
            Spacer(minLength: 0)
            if let subtitle {
                Text(subtitle).font(VFont.caption).foregroundStyle(VColor.textTertiary)
            }
        }
    }
}

// MARK: Ring gauge (270° arc, WHOOP-style)

struct VRing: View {
    /// 0…1 fill; nil renders the track only.
    let progress: Double?
    let tint: Color
    var lineWidth: CGFloat = 12
    var sweep: Double = 270

    var body: some View {
        ZStack {
            VArc(fraction: 1, sweep: sweep)
                .stroke(VColor.track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            VArc(fraction: max(0.002, min(1, progress ?? 0)), sweep: sweep)
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.55), tint],
                                    center: .center,
                                    startAngle: .degrees(VArc.startAngle(sweep)),
                                    endAngle: .degrees(VArc.startAngle(sweep) + sweep)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .opacity(progress == nil ? 0 : 1)
                .animation(.spring(response: 0.8, dampingFraction: 0.85), value: progress)
        }
        .padding(lineWidth / 2)
    }
}

/// An arc of `sweep` degrees, opening at the bottom, filled to `fraction`.
struct VArc: Shape {
    var fraction: Double
    var sweep: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    static func startAngle(_ sweep: Double) -> Double { 90 + (360 - sweep) / 2 }

    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let start = Self.startAngle(sweep)
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: r,
                 startAngle: .degrees(start), endAngle: .degrees(start + sweep * fraction), clockwise: false)
        return p
    }
}

/// Ring with a big number in the middle and a small label below — the Today headline trio.
struct VScoreRing: View {
    let title: String
    let value: String
    let unit: String?
    let progress: Double?
    let tint: Color
    var size: CGFloat = 108
    var lineWidth: CGFloat = 10

    var body: some View {
        VStack(spacing: VSpace.sm) {
            ZStack {
                VRing(progress: progress, tint: tint, lineWidth: lineWidth)
                    .frame(width: size, height: size)
                VStack(spacing: 0) {
                    Text(value)
                        .font(.system(size: size * 0.30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(progress == nil ? VColor.textTertiary : VColor.textPrimary)
                        .contentTransition(.numericText())
                    if let unit {
                        Text(unit).font(VFont.label).foregroundStyle(VColor.textTertiary)
                    }
                }
            }
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(VColor.textSecondary)
        }
    }
}

// MARK: Stat tile

struct VStatTile: View {
    let title: String
    let value: String
    var unit: String? = nil
    var tint: Color = VColor.textSecondary
    var systemImage: String? = nil
    var footnote: String? = nil
    var spark: [Double]? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: VSpace.sm) {
            HStack(spacing: VSpace.xs) {
                if let systemImage {
                    Image(systemName: systemImage).font(.caption.weight(.semibold)).foregroundStyle(tint)
                }
                Text(title).font(VFont.label).foregroundStyle(VColor.textSecondary)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(VFont.stat).monospacedDigit()
                    .foregroundStyle(value == "--" || value == "—" ? VColor.textTertiary : VColor.textPrimary)
                    .contentTransition(.numericText())
                if let unit { Text(unit).font(VFont.unit).foregroundStyle(VColor.textTertiary) }
            }
            if let spark, spark.count >= 2 {
                VSparkline(values: spark, tint: tint).frame(height: 26)
            } else if let footnote {
                Text(footnote).font(.caption2).foregroundStyle(VColor.textTertiary).lineLimit(2)
            }
        }
        .padding(VSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VColor.surfaceInset, in: RoundedRectangle(cornerRadius: VSpace.tileRadius, style: .continuous))
    }
}

// MARK: Sparkline (Robinhood-style line + soft area)

struct VSparkline: View {
    let values: [Double]
    let tint: Color
    var showsLast: Bool = false

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            AreaMark(x: .value("i", i), yStart: .value("min", lo), yEnd: .value("v", v))
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0)],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("i", i), y: .value("v", v))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.catmullRom)
            if showsLast, i == values.count - 1 {
                PointMark(x: .value("i", i), y: .value("v", v)).foregroundStyle(tint).symbolSize(30)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: lo...hi)
        .chartLegend(.hidden)
    }

    private var lo: Double { (values.min() ?? 0) - pad }
    private var hi: Double { (values.max() ?? 1) + pad }
    private var pad: Double { max(((values.max() ?? 1) - (values.min() ?? 0)) * 0.15, 0.5) }
}

// MARK: Hypnogram

struct VHypnogram: View {
    struct Segment: Identifiable {
        let id = UUID()
        let start: Int
        let end: Int
        let stage: String   // "wake"/"awake" | "light" | "rem" | "deep"
    }
    let segments: [Segment]
    let start: Int
    let end: Int

    private static let lanes: [String: (row: Int, color: Color)] = [
        "wake": (0, VColor.stageAwake), "awake": (0, VColor.stageAwake),
        "rem": (1, VColor.stageRem), "light": (2, VColor.stageLight), "deep": (3, VColor.stageDeep),
    ]

    var body: some View {
        GeometryReader { geo in
            let span = max(1, Double(end - start))
            let rowH = geo.size.height / 4
            ZStack(alignment: .topLeading) {
                ForEach(0..<4, id: \.self) { row in
                    Rectangle().fill(VColor.track.opacity(0.35))
                        .frame(height: 1)
                        .offset(y: CGFloat(row) * rowH + rowH / 2)
                }
                ForEach(segments) { seg in
                    if let lane = Self.lanes[seg.stage.lowercased()] {
                        let x = CGFloat(Double(seg.start - start) / span) * geo.size.width
                        let w = max(2, CGFloat(Double(seg.end - seg.start) / span) * geo.size.width)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(lane.color)
                            .frame(width: w, height: rowH * 0.72)
                            .offset(x: x, y: CGFloat(lane.row) * rowH + rowH * 0.14)
                    }
                }
            }
        }
    }
}

// MARK: Stage bar (proportional totals)

struct VStageBar: View {
    let awake: Double, light: Double, rem: Double, deep: Double
    var body: some View {
        let total = max(1, awake + light + rem + deep)
        GeometryReader { geo in
            HStack(spacing: 2) {
                seg(deep / total, VColor.stageDeep, geo.size.width)
                seg(rem / total, VColor.stageRem, geo.size.width)
                seg(light / total, VColor.stageLight, geo.size.width)
                seg(awake / total, VColor.stageAwake, geo.size.width)
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
    }
    private func seg(_ f: Double, _ c: Color, _ w: CGFloat) -> some View {
        Rectangle().fill(c).frame(width: max(0, w * CGFloat(f) - 2))
    }
}

// MARK: Pills, labels, empty states

struct VPill: View {
    let text: String
    var tint: Color = VColor.textSecondary
    var filled: Bool = false
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(filled ? Color.white : tint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(filled ? tint : tint.opacity(0.14), in: Capsule())
    }
}

/// The honest "as of" line every derived screen carries. Never a spinner implying live computation.
struct VAsOf: View {
    let dayKey: String?
    let computedAt: Date?
    var body: some View {
        HStack(spacing: VSpace.xs) {
            Image(systemName: "clock").font(.caption2)
            if let dayKey {
                Text("\(VFormat.dayLabel(dayKey)) · updated \(VFormat.relative(computedAt))")
            } else {
                Text("No scored day yet")
            }
        }
        .font(.caption)
        .foregroundStyle(VColor.textTertiary)
    }
}

struct VEmpty: View {
    let systemImage: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: VSpace.md) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(VColor.textTertiary)
            Text(title).font(VFont.cardTitle).foregroundStyle(VColor.textPrimary)
            Text(message).font(.footnote).foregroundStyle(VColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, VSpace.xl)
    }
}

/// Screen scaffold: canvas colour, large title, consistent padding.
struct VScreen<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            LazyVStack(spacing: VSpace.md) { content }
                .padding(.horizontal, VSpace.screenPadding)
                .padding(.bottom, VSpace.xxl)
        }
        .background(VColor.canvas.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .scrollIndicators(.hidden)
    }
}
