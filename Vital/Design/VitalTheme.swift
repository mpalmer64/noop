import SwiftUI

// Vital's own design tokens. Nothing here comes from StrandDesign: the point of the app is that the look
// is its own. Dark-first (near-black canvas, elevated cards, one saturated accent per metric) and fully
// dynamic so it reads as a native app in light mode too.

enum VColor {
    /// App canvas. Pure black in dark mode (OLED, WHOOP/Robinhood convention), grouped grey in light.
    static let canvas = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor.black : UIColor.systemGroupedBackground })
    /// Card surface.
    static let surface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.082, green: 0.082, blue: 0.094, alpha: 1) : UIColor.white })
    /// Inset surface inside a card (chart wells, secondary tiles).
    static let surfaceInset = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.125, green: 0.125, blue: 0.141, alpha: 1) : UIColor.systemGray6 })
    /// Hairline on cards.
    static let hairline = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor.white.withAlphaComponent(0.06) : UIColor.black.withAlphaComponent(0.05) })
    /// Ring / chart track.
    static let track = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor.white.withAlphaComponent(0.10) : UIColor.black.withAlphaComponent(0.08) })

    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color(uiColor: .tertiaryLabel)

    // Metric accents.
    static let recoveryHigh = Color(red: 0.24, green: 0.86, blue: 0.52)   // green
    static let recoveryMid  = Color(red: 1.00, green: 0.79, blue: 0.30)   // amber
    static let recoveryLow  = Color(red: 1.00, green: 0.35, blue: 0.37)   // red
    static let strain       = Color(red: 0.29, green: 0.55, blue: 1.00)   // blue
    static let sleep        = Color(red: 0.61, green: 0.55, blue: 1.00)   // lavender
    static let hrv          = Color(red: 0.23, green: 0.78, blue: 0.84)   // teal
    static let heart        = Color(red: 1.00, green: 0.42, blue: 0.42)   // coral
    static let rhr          = Color(red: 1.00, green: 0.55, blue: 0.35)   // orange
    static let respiration  = Color(red: 0.55, green: 0.80, blue: 0.95)   // sky
    static let temperature  = Color(red: 0.98, green: 0.65, blue: 0.45)
    static let oxygen       = Color(red: 0.40, green: 0.75, blue: 1.00)

    /// Recovery band colour for a 0–100 score, matching NOOP's red / yellow / green thresholds.
    static func recovery(_ score: Double?) -> Color {
        guard let score else { return textTertiary }
        switch VitalBand.recovery(score) {
        case .low: return recoveryLow
        case .mid: return recoveryMid
        case .high: return recoveryHigh
        }
    }

    // Sleep stage colours (hypnogram + stage bars).
    static let stageAwake = Color(red: 1.00, green: 0.62, blue: 0.40)
    static let stageLight = Color(red: 0.62, green: 0.58, blue: 1.00)
    static let stageRem   = Color(red: 0.40, green: 0.80, blue: 0.95)
    static let stageDeep  = Color(red: 0.36, green: 0.34, blue: 0.85)
}

enum VitalBand {
    case low, mid, high
    static func recovery(_ score: Double) -> VitalBand {
        if score < 34 { return .low }
        if score < 67 { return .mid }
        return .high
    }
}

enum VFont {
    /// Hero numeral (live BPM). Sized at the call site through `@ScaledMetric` so it follows Dynamic Type.
    static func hero(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    /// Card headline numeral. Text styles, not fixed sizes, so the user's text-size setting is honoured.
    static let display = Font.system(.largeTitle, design: .rounded, weight: .semibold)
    /// Tile numeral.
    static let stat = Font.system(.title2, design: .rounded, weight: .semibold)
    static let statSmall = Font.system(.title3, design: .rounded, weight: .semibold)
    static let title = Font.title2.weight(.semibold)
    static let cardTitle = Font.subheadline.weight(.semibold)
    static let body = Font.body
    static let caption = Font.caption
    static let label = Font.caption.weight(.medium)
    static let unit = Font.footnote.weight(.medium)
}

enum VSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let cardRadius: CGFloat = 22
    static let tileRadius: CGFloat = 16
    static let screenPadding: CGFloat = 16
}

// MARK: - Formatting helpers shared by screens

enum VFormat {
    static func int(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))" } ?? "--" }
    static func int(_ v: Int?) -> String { v.map(String.init) ?? "--" }
    static func one(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "--" }

    /// Strain on WHOOP's 0–21 scale from NOOP's 0–100 Effort axis.
    static func whoopStrain(_ effort: Double?) -> String {
        guard let effort else { return "--" }
        return String(format: "%.1f", effort * 21.0 / 100.0)
    }

    static func hoursMinutes(_ minutes: Double?) -> String {
        guard let m = minutes else { return "--" }
        let h = Int(m) / 60, mm = Int(m) % 60
        return h > 0 ? "\(h)h \(mm)m" : "\(mm)m"
    }

    static func clock(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .omitted, time: .shortened)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "never" }
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86_400 { return "\(s / 3600) h ago" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "Today", "Yesterday", or a short weekday + date for a YYYY-MM-DD key.
    static func dayLabel(_ key: String) -> String {
        guard let d = date(fromKey: key) else { return key }
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func date(fromKey key: String) -> Date? { keyFormatter.date(from: key) }
}
