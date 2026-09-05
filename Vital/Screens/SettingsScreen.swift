import SwiftUI
import UniformTypeIdentifiers

/// Strap, profile (the inputs scoring needs), data import, and the notices the licence requires.
struct SettingsScreen: View {
    @EnvironmentObject private var model: VitalModel
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @AppStorage(VitalAppearance.key) private var appearance: VitalAppearance = .dark
    @AppStorage(VitalNotifications.morningAlertKey) private var morningAlert = false
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.imperial.rawValue

    var body: some View {
        NavigationStack {
            Form {
                strapSection
                profileSection
                hapticsSection
                dataSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(VColor.canvas)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip, .folder]) { result in
                if case .success(let url) = result {
                    Task { await model.importPickedFile(url) }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.success, trigger: model.importStatus) { _, new in
            if case .done = new { return true } else { return false }
        }
    }

    // MARK: Sections

    private var strapSection: some View {
        Section {
            LabeledContent("Status", value: model.live.connected ? (model.live.bonded ? "Connected" : "Bonding…") : "Not connected")
            if let fw = model.live.strapFirmware { LabeledContent("Firmware", value: fw) }
            if let v = model.live.whoop5Variant { LabeledContent("Model", value: v) }
            if let pct = model.live.batteryPct { LabeledContent("Battery", value: "\(Int(pct.rounded()))%") }
            LabeledContent("Last offload", value: VFormat.relative(model.sync.lastSyncedAt))
            if model.live.connected {
                Button("Disconnect", role: .destructive) { model.disconnect() }
            } else {
                Button("Connect WHOOP 4.0") { model.connect(.whoop4) }
                Button("Connect WHOOP 5.0 / MG") { model.connect(.whoop5mg) }
            }
        } header: { Text("Strap") } footer: {
            Text("Only one app can hold the strap over Bluetooth. Disconnect it in NOOP before connecting here.")
        }
    }

    private var profileSection: some View {
        ProfileSection(profile: model.profile)
    }

    private var hapticsSection: some View {
        HapticsSection()
    }

    private var dataSection: some View {
        Section {
            LabeledContent("Days scored on this phone", value: "\(model.derived.computedDays)")
            LabeledContent("Days from WHOOP export", value: "\(model.derived.importedDays)")
            Button {
                showImporter = true
            } label: {
                Label("Import WHOOP export (.zip)", systemImage: "square.and.arrow.down")
            }
            .disabled(model.importStatus == .importing)
            importStatusRow
            Button {
                Task { await model.runScoring(force: true, skipIfUnchanged: false) }
            } label: {
                Label(model.isScoring ? "Scoring…" : "Re-score recent days", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScoring)
        } header: { Text("Data") } footer: {
            Text("Request your export at app.whoop.com → Profile → Data export. Imported days seed the baselines recovery needs; days the strap offloads here are scored on-device with NOOP's engine.")
        }
    }

    @ViewBuilder
    private var importStatusRow: some View {
        switch model.importStatus {
        case .idle:
            EmptyView()
        case .importing:
            HStack { ProgressView().controlSize(.small); Text("Importing…").foregroundStyle(VColor.textSecondary) }
        case .done(let c, let s, let w, let at):
            LabeledContent("Last import", value: "\(c) days · \(s) sleeps · \(w) workouts · \(VFormat.relative(at))")
                .font(.footnote)
        case .failed(let msg):
            Text(msg).font(.footnote).foregroundStyle(VColor.recoveryLow)
        }
    }

    private var aboutSection: some View {
        Section {
            Picker("Appearance", selection: $appearance) {
                ForEach(VitalAppearance.allCases) { a in Text(a.label).tag(a) }
            }
            Picker("Units", selection: $unitSystemRaw) {
                Text("Imperial (lb, ft, °F, mi)").tag(UnitSystem.imperial.rawValue)
                Text("Metric (kg, cm, °C, km)").tag(UnitSystem.metric.rawValue)
            }
            Toggle("Morning recovery alert", isOn: $morningAlert)
                .onChange(of: morningAlert) { _, on in
                    guard on else { return }
                    Task { if await !VitalNotifications.requestPermission() { morningAlert = false } }
                }
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            NavigationLink("Licence & attribution") { NoticesScreen() }
        } header: { Text("About") } footer: {
            Text("Vital is a personal, non-commercial build on the NOOP project. Not affiliated with WHOOP. Not a medical device; every metric is an approximation.")
        }
    }
}

/// The notices the PolyForm Noncommercial licence requires travel with every copy.
struct NoticesScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VSpace.lg) {
                Text("Vital is built on NOOP, an independent, offline-first companion for WHOOP straps, and reuses NOOP's Bluetooth collection layer, on-device store and scoring engine unchanged.")
                Text("NOOP is licensed under the PolyForm Noncommercial License 1.0.0.\nRequired Notice: Copyright 2026 NoopApp\nhttps://polyformproject.org/licenses/noncommercial/1.0.0")
                    .font(.footnote.monospaced())
                Text("This build may be used and shared for non-commercial purposes only. It may not be sold or distributed through an app store.")
                Text("NOOP builds on community interoperability research (johnmiddleton12/my-whoop for WHOOP 4.0 protocol facts; b-nnett/goose for WHOOP 5.0 / MG). Third-party components: GRDB.swift (MIT), ZIPFoundation (MIT).")
                Text("\"WHOOP\" is used only to identify the hardware this app interoperates with. Not affiliated with, endorsed by, or connected to WHOOP, Inc. This is not a medical device.")
            }
            .font(.callout)
            .foregroundStyle(VColor.textSecondary)
            .padding(VSpace.screenPadding)
        }
        .background(VColor.canvas)
        .navigationTitle("Licence & attribution")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Profile editors bind straight to NOOP's `ProfileStore` (UserDefaults-backed), so the inputs strain and
/// recovery use are the same ones NOOP would read.
private struct ProfileSection: View {
    @ObservedObject var profile: ProfileStore
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.imperial.rawValue
    private var imperial: Bool { unitSystemRaw != UnitSystem.metric.rawValue }

    var body: some View {
        Section {
            DatePicker("Date of birth", selection: $profile.dateOfBirth,
                       in: ProfileStore.dateOfBirthRange, displayedComponents: .date)
            Picker("Sex", selection: $profile.sex) {
                Text("Male").tag("male")
                Text("Female").tag("female")
            }
            HStack {
                Text("Weight")
                Spacer()
                TextField(imperial ? "lb" : "kg", value: Binding<Double>(
                    get: { imperial ? (UnitFormatter.kgToPounds(profile.weightKg) * 10).rounded() / 10 : profile.weightKg },
                    set: { profile.weightKg = imperial ? $0 / UnitFormatter.poundsPerKilogram : $0 }),
                    format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                Text(imperial ? "lb" : "kg").foregroundStyle(VColor.textTertiary)
            }
            if imperial {
                HStack {
                    Text("Height")
                    Spacer()
                    TextField("ft", value: Binding<Int>(
                        get: { UnitFormatter.cmToFeetInches(profile.heightCm).feet },
                        set: { profile.heightCm = VitalUnits.cm(feet: $0, inches: UnitFormatter.cmToFeetInches(profile.heightCm).inches) }),
                        format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 44)
                    Text("ft").foregroundStyle(VColor.textTertiary)
                    TextField("in", value: Binding<Int>(
                        get: { UnitFormatter.cmToFeetInches(profile.heightCm).inches },
                        set: { profile.heightCm = VitalUnits.cm(feet: UnitFormatter.cmToFeetInches(profile.heightCm).feet, inches: min(11, max(0, $0))) }),
                        format: .number)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 44)
                    Text("in").foregroundStyle(VColor.textTertiary)
                }
            } else {
                HStack {
                    Text("Height")
                    Spacer()
                    TextField("cm", value: $profile.heightCm, format: .number.precision(.fractionLength(0)))
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90)
                    Text("cm").foregroundStyle(VColor.textTertiary)
                }
            }
            HStack {
                Text("Max heart rate")
                Spacer()
                TextField("auto", value: Binding<Int?>(
                    get: { profile.hrMaxOverride > 0 ? profile.hrMaxOverride : nil },
                    set: { profile.hrMaxOverride = $0 ?? 0 }), format: .number)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90)
                Text("bpm").foregroundStyle(VColor.textTertiary)
            }
        } header: { Text("Profile") } footer: {
            Text("Strain uses your max heart rate (\(profile.hrMax) bpm, \(profile.hrMaxOverride > 0 ? "set by you" : "estimated from age")). Recovery and sleep need a few nights of history to calibrate.")
        }
    }
}

/// Every way the strap can buzz, each its own switch. Nothing here fires unless the strap is bonded.
private struct HapticsSection: View {
    @EnvironmentObject private var model: VitalModel
    @AppStorage(VitalHaptics.moveReminderKey) private var move = true
    @AppStorage(VitalHaptics.zoneCoachingKey) private var zones = true
    @AppStorage(VitalHaptics.morningBuzzKey) private var morning = true
    @AppStorage(VitalHaptics.strainTargetKey) private var strainTarget = true
    @AppStorage(VitalHaptics.hapticClockKey) private var clock = false
    @AppStorage(VitalHaptics.clockStyleKey) private var clockStyle = "simple"
    @AppStorage(HapticPrefs.workout) private var workoutBuzz = true
    @AppStorage(VitalHaptics.alarmEnabledKey) private var alarmOn = false
    @AppStorage(VitalHaptics.alarmMinutesKey) private var alarmMinutes = 7 * 60
    @AppStorage(VitalHaptics.windDownEnabledKey) private var windDownOn = false
    @AppStorage(VitalHaptics.windDownMinutesKey) private var windDownMinutes = 22 * 60 + 30
    @AppStorage("inactivity.enabled") private var inactivityDetector = false
    @AppStorage("notif.masterEnabled") private var notifMaster = false

    var body: some View {
        Section {
            Toggle("Move reminder", isOn: Binding(
                get: { move && inactivityDetector },
                set: { on in move = on; inactivityDetector = on; if on { notifMaster = true } }))
            Toggle("Zone coaching during activities", isOn: $zones)
            Toggle("Activity start / stop", isOn: $workoutBuzz)
            Toggle("Recovery is in (morning)", isOn: $morning)
            Toggle("Strain target reached", isOn: $strainTarget)
            Toggle("Double-tap taps the time", isOn: $clock)
            if clock {
                Picker("Clock style", selection: $clockStyle) {
                    Text("Simple (hours, then quarters)").tag("simple")
                    Text("Digits (tens long, units short)").tag("digits")
                }
                Button("Buzz the time now") {
                    clockStyle == "digits" ? model.ble.buzzTimeNow(is24h: false) : model.buzzTimeSimple()
                }
                .disabled(!model.live.bonded)
            }
            Toggle("Strap alarm", isOn: $alarmOn)
                .onChange(of: alarmOn) { _, _ in model.applyAlarm() }
            if alarmOn {
                DatePicker("Wake time", selection: minutesBinding($alarmMinutes), displayedComponents: .hourAndMinute)
                    .onChange(of: alarmMinutes) { _, _ in model.applyAlarm() }
            }
            Toggle("Wind-down reminder", isOn: $windDownOn)
                .onChange(of: windDownOn) { _, _ in model.applyWindDown() }
            if windDownOn {
                DatePicker("In bed by", selection: minutesBinding($windDownMinutes), displayedComponents: .hourAndMinute)
                    .onChange(of: windDownMinutes) { _, _ in model.applyWindDown() }
            }
            Button("Test buzz") { model.buzz(loops: 1) }.disabled(!model.live.bonded)
        } header: { Text("Strap haptics") } footer: {
            Text("Move reminder uses the strap's motion to spot long sitting. Zone coaching buzzes three times entering zone 5 and once dropping back to zone 1. Simple clock: one buzz per hour (12 at twelve), a long pause, then one buzz per quarter hour — 4:35 is four buzzes, pause, two buzzes. Count them; a second double-tap within 30 seconds is ignored so sequences never overlap. The alarm runs on the strap itself and fires even if the phone is out of reach; a notification backs it up.")
        }
    }

    private func minutesBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
            set: { d in minutes.wrappedValue = Calendar.current.component(.hour, from: d) * 60 + Calendar.current.component(.minute, from: d) })
    }
}
