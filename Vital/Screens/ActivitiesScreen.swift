import Charts
import StrandAnalytics
import SwiftUI
import WhoopProtocol
import WhoopStore

/// Start, log, and review activities. Detected sessions arrive from NOOP's engine after each offload.
struct ActivitiesScreen: View {
    @EnvironmentObject private var model: VitalModel
    @State private var showSportPicker = false
    @State private var showLogSheet = false
    @State private var detail: ActivityRoute?

    /// `navigationDestination(item:)` wants Hashable; a row's start + sport + source identifies it.
    struct ActivityRoute: Identifiable, Hashable {
        let row: WorkoutRow
        var id: String { row.id }
        static func == (a: ActivityRoute, b: ActivityRoute) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    var body: some View {
        VScreen(title: "Activity") {
            if model.activity != nil {
                LiveActivityCard()
            } else {
                HStack(spacing: VSpace.md) {
                    Button { showSportPicker = true } label: {
                        Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, VSpace.chipH)
                    }
                    .buttonStyle(.borderedProminent).tint(VColor.strain)
                    Button { showLogSheet = true } label: {
                        Label("Log past", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity).padding(.vertical, VSpace.chipH)
                    }
                    .buttonStyle(.bordered)
                }
                .font(.headline)
            }

            weekCard

            if model.workouts.isEmpty {
                VCard {
                    VEmpty(systemImage: "figure.run", title: "No activities yet",
                           message: "Start one here, log one you forgot, or let the strap find them: sustained-effort bouts are detected automatically when the day is scored after an offload.")
                }
            } else {
                ForEach(groupedByDay, id: \.day) { group in
                    VSectionTitle(text: VFormat.dayLabel(group.day))
                    ForEach(group.rows) { row in
                        Button { detail = ActivityRoute(row: row) } label: { ActivityRow(row: row) }
                            .buttonStyle(.vPress)
                            .accessibilityHint("Opens this activity")
                    }
                }
                Text("Detected activities come from the strap's banked heart rate and motion after each offload; they carry a “Detected” badge.")
                    .font(.caption2).foregroundStyle(VColor.textTertiary).padding(.top, VSpace.xs)
            }
        }
        .toolbar { SettingsToolbarButton() }
        .sheet(isPresented: $showSportPicker) {
            SportPickerSheet { sport in model.startActivity(sport: sport) }
        }
        .sheet(isPresented: $showLogSheet) { LogActivitySheet() }
        // Reading, so a push (like Nights); the sport picker and log form stay sheets because they take input.
        .navigationDestination(item: $detail) { route in ActivityDetailView(row: route.row) }
        .sensoryFeedback(.success, trigger: model.workouts.count) { old, new in new > old }
        .task { await model.reloadWorkouts() }
    }

    private struct DayGroup { let day: String; let rows: [WorkoutRow] }

    private var groupedByDay: [DayGroup] {
        var order: [String] = []
        var map: [String: [WorkoutRow]] = [:]
        for r in model.workouts {
            let key = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(r.startTs)))
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(r)
        }
        return order.map { DayGroup(day: $0, rows: map[$0] ?? []) }
    }

    private var weekCard: some View {
        let weekAgo = Int(Date().addingTimeInterval(-7 * 86_400).timeIntervalSince1970)
        let rows = model.workouts.filter { $0.startTs >= weekAgo }
        let minutes = rows.compactMap(\.durationS).reduce(0, +) / 60
        let strain = rows.compactMap(\.strain).reduce(0, +)
        let kcal = rows.compactMap(\.energyKcal).reduce(0, +)
        return HStack(spacing: VSpace.md) {
            VStatTile(title: "This week", value: "\(rows.count)", unit: rows.count == 1 ? "activity" : "activities",
                      tint: VColor.strain, systemImage: "figure.run")
            VStatTile(title: "Active time", value: VFormat.hoursMinutes(minutes), tint: VColor.strain, systemImage: "timer")
            VStatTile(title: "Strain", value: VFormat.whoopStrain(strain), tint: VColor.strain, systemImage: "flame.fill",
                      footnote: kcal > 0 ? "\(Int(kcal)) kcal" : nil)
        }
    }
}

// MARK: - Row

struct ActivityRow: View {
    let row: WorkoutRow

    var body: some View {
        HStack(spacing: VSpace.md) {
            Image(systemName: ActivityIcon.symbol(for: row.sport))
                .font(.title3)
                .foregroundStyle(VColor.strain)
                .frame(width: 40, height: 40)
                .background(VColor.strain.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(WorkoutSource.displaySport(row.sport)).font(.subheadline.weight(.semibold))
                    sourceBadge
                }
                Text("\(VFormat.clock(row.startTs)) · \(VFormat.hoursMinutes((row.durationS ?? Double(row.endTs - row.startTs)) / 60))")
                    .font(.caption).foregroundStyle(VColor.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(VFormat.whoopStrain(row.strain)).font(VFont.statSmall).monospacedDigit()
                Text("strain").font(VFont.label).foregroundStyle(VColor.textTertiary)
            }
        }
        .padding(VSpace.md)
        .background(VColor.surface, in: RoundedRectangle(cornerRadius: VSpace.tileRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VSpace.tileRadius, style: .continuous).strokeBorder(VColor.hairline, lineWidth: 1))
    }

    @ViewBuilder private var sourceBadge: some View {
        switch WorkoutSource.classify(row.source) {
        case .detected: VPill(text: "Detected", tint: VColor.hrv)
        case .whoop: VPill(text: "WHOOP", tint: VColor.textSecondary)
        case .manual: EmptyView()
        default: VPill(text: "Imported", tint: VColor.textSecondary)
        }
    }
}

enum ActivityIcon {
    static func symbol(for sport: String) -> String {
        let s = sport.lowercased()
        if s.contains("run") { return "figure.run" }
        if s.contains("walk") || s.contains("hik") { return "figure.walk" }
        if s.contains("cycl") || s.contains("bik") || s.contains("spin") { return "figure.outdoor.cycle" }
        if s.contains("swim") { return "figure.pool.swim" }
        if s.contains("strength") || s.contains("weight") || s.contains("lift") || s.contains("functional") { return "dumbbell.fill" }
        if s.contains("yoga") || s.contains("stretch") || s.contains("pilates") { return "figure.yoga" }
        if s.contains("row") { return "figure.rower" }
        if s.contains("hiit") || s.contains("cross") || s.contains("box") { return "figure.highintensity.intervaltraining" }
        if s.contains("basketball") { return "figure.basketball" }
        if s.contains("soccer") || s.contains("football") { return "figure.soccer" }
        if s.contains("tennis") || s.contains("pickle") || s.contains("padel") { return "figure.tennis" }
        if s.contains("golf") { return "figure.golf" }
        if s.contains("ski") || s.contains("snow") { return "figure.skiing.downhill" }
        if s.contains("climb") { return "figure.climbing" }
        if s.contains("sauna") || s.contains("ice") { return "thermometer.sun" }
        return "figure.mixed.cardio"
    }
}

// MARK: - Live session

struct LiveActivityCard: View {
    @EnvironmentObject private var model: VitalModel
    @State private var now = Date()
    @State private var confirmEnd = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        if let a = model.activity {
            card(a, live: model.activityLive)
        }
    }

    private func card(_ a: ActiveActivity, live: ActivityLive?) -> some View {
        VCard(padding: VSpace.xl) {
            VStack(spacing: VSpace.lg) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: ActivityIcon.symbol(for: a.sport)).foregroundStyle(VColor.strain)
                        Text(a.sport).font(VFont.cardTitle)
                    }
                    Spacer()
                    VPill(text: a.isPaused ? "Paused" : "Recording",
                          tint: a.isPaused ? VColor.textSecondary : VColor.recoveryHigh, filled: !a.isPaused)
                }
                Text(elapsedText(a.elapsed(at: now)))
                    .font(VFont.timer).monospacedDigit()
                    .contentTransition(.numericText())
                HStack(alignment: .top) {
                    stat("Heart rate", model.bpm.map(String.init) ?? "--", "bpm", zoneColor(live?.currentZone ?? 0))
                    Spacer()
                    stat("Strain", VFormat.whoopStrain(live?.strain), "of 21", VColor.strain)
                    Spacer()
                    stat("Calories", live.map { "\(Int($0.kcal))" } ?? "--", "kcal", VColor.rhr)
                    Spacer()
                    stat("Avg · Peak", "\(a.avgHr.map(String.init) ?? "--") · \(a.peakHr.map(String.init) ?? "--")", nil, VColor.heart)
                }
                if let z = live?.zoneSeconds, z.reduce(0, +) > 0 {
                    ZoneBar(seconds: z, currentZone: live?.currentZone ?? 0)
                }
                HStack(spacing: VSpace.md) {
                    Button {
                        a.isPaused ? model.resumeActivity() : model.pauseActivity()
                    } label: {
                        Label(a.isPaused ? "Resume" : "Pause", systemImage: a.isPaused ? "play.fill" : "pause.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, VSpace.sm)
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive) { confirmEnd = true } label: {
                        Label("End", systemImage: "stop.fill").frame(maxWidth: .infinity).padding(.vertical, VSpace.sm)
                    }
                    .buttonStyle(.borderedProminent).tint(VColor.heart)
                }
                .font(.headline)
            }
        }
        .onReceive(tick) { now = $0 }
        .confirmationDialog("End activity?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("Save activity") { Task { await model.endActivity() } }
            Button("Discard", role: .destructive) { model.discardActivity() }
            Button("Keep going", role: .cancel) {}
        }
    }

    private func elapsedText(_ t: TimeInterval) -> String {
        let s = Int(t); let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    private func stat(_ label: String, _ value: String, _ unit: String?, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(VFont.label).foregroundStyle(VColor.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(VFont.statSmall).monospacedDigit().foregroundStyle(tint)
                if let unit { Text(unit).font(.caption2).foregroundStyle(VColor.textTertiary) }
            }
        }
    }
}

func zoneColor(_ zone: Int) -> Color {
    switch zone {
    case 5: return VColor.recoveryLow
    case 4: return VColor.rhr
    case 3: return VColor.recoveryMid
    case 2: return VColor.recoveryHigh
    case 1: return VColor.hrv
    default: return VColor.textTertiary
    }
}

/// Five zone segments sized by time spent; the current zone is drawn at full strength.
struct ZoneBar: View {
    let seconds: [Double]
    var currentZone: Int = 0
    var body: some View {
        let total = max(1, seconds.reduce(0, +))
        VStack(spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { i in
                        let f = seconds[i] / total
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(zoneColor(i + 1).opacity(currentZone == i + 1 ? 1 : 0.7))
                            .frame(width: max(f > 0 ? 6 : 0, geo.size.width * CGFloat(f) - 3))
                    }
                }
            }
            .frame(height: 12)
            HStack {
                ForEach(0..<5, id: \.self) { i in
                    VStack(spacing: 1) {
                        Text("Z\(i + 1)").font(.caption2.weight(.semibold)).foregroundStyle(zoneColor(i + 1))
                        Text(VFormat.hoursMinutes(seconds[i] / 60)).font(.caption2).foregroundStyle(VColor.textTertiary).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Sport picker

struct SportPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let onPick: (String) -> Void

    private var sports: [WorkoutCatalog.Sport] {
        query.isEmpty ? WorkoutCatalog.all : WorkoutCatalog.matching(query)
    }

    var body: some View {
        NavigationStack {
            List {
                if !query.isEmpty, !sports.contains(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
                    Button { pick(query) } label: { Label("Use “\(query)”", systemImage: "plus") }
                }
                ForEach(sports) { s in
                    Button { pick(s.name) } label: {
                        HStack {
                            Image(systemName: ActivityIcon.symbol(for: s.name)).foregroundStyle(VColor.strain).frame(width: 28)
                            Text(s.name).foregroundStyle(VColor.textPrimary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(VColor.canvas)
            .searchable(text: $query, prompt: "Sport")
            .navigationTitle("Choose a sport")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func pick(_ name: String) { onPick(name); dismiss() }
}

// MARK: - Log a past activity

struct LogActivitySheet: View {
    @EnvironmentObject private var model: VitalModel
    @Environment(\.dismiss) private var dismiss
    @State private var sport = "Running"
    @State private var start = Date().addingTimeInterval(-3600)
    @State private var end = Date()
    @State private var showSports = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showSports = true } label: {
                        HStack {
                            Text("Sport"); Spacer()
                            Text(sport).foregroundStyle(VColor.textSecondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(VColor.textTertiary)
                        }
                    }
                    .foregroundStyle(VColor.textPrimary)
                    DatePicker("Start", selection: $start, in: ...Date())
                    DatePicker("End", selection: $end, in: start...Date())
                } footer: {
                    Text("Heart rate the strap already recorded for this window fills in strain, average and peak HR, and calories.")
                }
                Section {
                    LabeledContent("Duration", value: VFormat.hoursMinutes(end.timeIntervalSince(start) / 60))
                }
            }
            .scrollContentBackground(.hidden)
            .background(VColor.canvas)
            .navigationTitle("Log activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        saving = true
                        Task { await model.logActivity(sport: sport, start: start, end: end); dismiss() }
                    }
                    .disabled(saving || end <= start)
                }
            }
            .sheet(isPresented: $showSports) { SportPickerSheet { sport = $0 } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Detail

struct ActivityDetailView: View {
    @EnvironmentObject private var model: VitalModel
    @Environment(\.dismiss) private var dismiss
    let row: WorkoutRow
    @State private var hr: [HRSample] = []
    @State private var confirmDelete = false

    var body: some View {
            ScrollView {
                VStack(spacing: VSpace.md) {
                    VCard(padding: VSpace.xl) {
                        VStack(alignment: .leading, spacing: VSpace.md) {
                            HStack {
                                Image(systemName: ActivityIcon.symbol(for: row.sport)).font(.title2).foregroundStyle(VColor.strain)
                                VStack(alignment: .leading) {
                                    Text(WorkoutSource.displaySport(row.sport)).font(VFont.title)
                                    Text("\(Date(timeIntervalSince1970: TimeInterval(row.startTs)).formatted(date: .abbreviated, time: .shortened)) – \(VFormat.clock(row.endTs))")
                                        .font(.footnote).foregroundStyle(VColor.textSecondary)
                                }
                                Spacer()
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(VFormat.whoopStrain(row.strain)).font(VFont.display).monospacedDigit()
                                Text("strain").font(VFont.unit).foregroundStyle(VColor.textTertiary)
                            }
                        }
                    }
                    HStack(spacing: VSpace.md) {
                        VStatTile(title: "Duration", value: VFormat.hoursMinutes((row.durationS ?? Double(row.endTs - row.startTs)) / 60), tint: VColor.strain, systemImage: "timer")
                        VStatTile(title: "Calories", value: VFormat.int(row.energyKcal), unit: "kcal", tint: VColor.rhr, systemImage: "flame.fill")
                    }
                    HStack(spacing: VSpace.md) {
                        VStatTile(title: "Avg HR", value: VFormat.int(row.avgHr), unit: "bpm", tint: VColor.heart, systemImage: "heart.fill")
                        VStatTile(title: "Peak HR", value: VFormat.int(row.maxHr), unit: "bpm", tint: VColor.heart, systemImage: "bolt.heart.fill")
                    }
                    if let m = row.distanceM {
                        VStatTile(title: "Distance", value: VitalUnits.distance(meters: m), tint: VColor.strain, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    if let pct = ActivityZones.percentages(row.zonesJSON) {
                        VCard {
                            VStack(alignment: .leading, spacing: VSpace.md) {
                                VCardHeader(title: "Heart rate zones", tint: VColor.strain, systemImage: "chart.bar.fill")
                                let total = (row.durationS ?? Double(row.endTs - row.startTs))
                                ZoneBar(seconds: pct.map { $0 / 100 * total })
                            }
                        }
                    }
                    if hr.count >= 2 {
                        VCard {
                            VStack(alignment: .leading, spacing: VSpace.md) {
                                VCardHeader(title: "Heart rate", subtitle: "\(hr.count) samples", tint: VColor.heart, systemImage: "waveform.path.ecg")
                                VSparkline(values: MetricSeriesBuilder.bucketMeans(hr, seconds: max(30, (row.endTs - row.startTs) / 120)), tint: VColor.heart)
                                    .frame(height: 120)
                            }
                        }
                    }
                    HStack {
                        VPill(text: sourceLabel, tint: VColor.textSecondary)
                        Spacer()
                    }
                }
                .padding(VSpace.screenPadding)
            }
            .background(VColor.canvas)
            .navigationTitle(WorkoutSource.displaySport(row.sport))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if WorkoutSource.classify(row.source) == .manual {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    }
                }
            }
            .confirmationDialog("Delete this activity?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await model.deleteActivity(row); dismiss() } }
            }
            .task { hr = await model.repo.hrSamples(from: row.startTs, to: row.endTs, limit: 20_000) }
    }

    private var sourceLabel: String {
        switch WorkoutSource.classify(row.source) {
        case .detected: return "Detected from strap data"
        case .manual: return "Recorded in Vital"
        case .whoop: return "From WHOOP export"
        default: return "Imported"
        }
    }
}

extension WorkoutRow: Identifiable {
    public var id: String { "\(startTs)-\(sport)-\(source)" }
}
