import StrandAnalytics
import SwiftUI
import WhoopStore

/// Today's journal: tap Yes/No on the behaviours from the last 24 hours. Answers land under the scored
/// day so they line up with the recovery they influenced.
struct JournalCard: View {
    @EnvironmentObject private var model: VitalModel
    let dayKey: String
    @State private var answers: [String: Bool] = [:]
    @State private var questions: [String] = VitalJournal.questions
    @State private var showInsights = false
    @State private var expanded = false

    var body: some View {
        VCard {
            VStack(alignment: .leading, spacing: VSpace.md) {
                VCardHeader(title: "Journal",
                            subtitle: answers.isEmpty ? "Not logged yet" : "\(answers.count) of \(questions.count) answered",
                            tint: VColor.sleep, systemImage: "book.closed.fill")
                let shown = expanded ? questions : Array(questions.prefix(4))
                ForEach(shown, id: \.self) { q in
                    HStack {
                        Text(VitalJournal.shortLabel(q)).font(.subheadline)
                        Spacer()
                        answerButtons(q)
                    }
                }
                HStack {
                    Button(expanded ? "Show fewer" : "All \(questions.count) behaviours") { withAnimation { expanded.toggle() } }
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    Button { showInsights = true } label: {
                        Label("What moves my recovery", systemImage: "sparkles").font(.footnote.weight(.semibold))
                    }
                }
                .buttonStyle(.plain).foregroundStyle(VColor.hrv)
            }
        }
        .task(id: dayKey) {
            questions = await model.journalQuestions()
            answers = await model.journalAnswers(day: dayKey)
        }
        .sheet(isPresented: $showInsights) { JournalInsightsSheet() }
    }

    private func answerButtons(_ q: String) -> some View {
        HStack(spacing: 6) {
            pill("No", selected: answers[q] == false, tint: VColor.textSecondary) { set(q, false) }
            pill("Yes", selected: answers[q] == true, tint: VColor.sleep) { set(q, true) }
        }
    }

    private func pill(_ text: String, selected: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.caption.weight(.semibold))
                .foregroundStyle(selected ? Color.white : tint)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? tint : tint.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func set(_ q: String, _ yes: Bool) {
        answers[q] = yes
        Task { await model.answerJournal(day: dayKey, question: q, yes: yes) }
    }
}

/// Ranked behaviour effects on recovery, HRV and sleep, from every journal day on record (imported WHOOP
/// journal included). Uses NOOP's BehaviorInsights, including its significance test.
struct JournalInsightsSheet: View {
    @EnvironmentObject private var model: VitalModel
    @Environment(\.dismiss) private var dismiss
    @State private var outcome: Outcome = .recovery
    @State private var entries: [JournalEntry] = []

    enum Outcome: String, CaseIterable, Identifiable {
        case recovery, hrv, sleep
        var id: String { rawValue }
        var label: String { self == .hrv ? "HRV" : rawValue.capitalized }
        var unit: String { self == .recovery ? "%" : (self == .hrv ? " ms" : " h") }
        func pick(_ d: DailyMetric) -> Double? {
            switch self {
            case .recovery: return d.recovery
            case .hrv: return d.avgHrv
            case .sleep: return d.totalSleepMin.map { $0 / 60 }
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: VSpace.md) {
                    Picker("Outcome", selection: $outcome) {
                        ForEach(Outcome.allCases) { o in Text(o.label).tag(o) }
                    }
                    .pickerStyle(.segmented)
                    let effects = VitalJournal.effects(entries: entries, days: model.derived.days,
                                                       outcome: outcome.pick, outcomeName: outcome.label)
                    if effects.isEmpty {
                        VCard {
                            VEmpty(systemImage: "sparkles", title: "Not enough journal days yet",
                                   message: "Each behaviour needs at least \(BehaviorInsights.minGroupForSignificance) yes-days and \(BehaviorInsights.minGroupForSignificance) no-days with a scored \(outcome.label.lowercased()).")
                        }
                    } else {
                        ForEach(effects, id: \.behavior) { e in effectRow(e) }
                        Text("Days with vs without each behaviour, \(entries.count) journal entries on record. Correlation, not causation; the badge marks effects unlikely to be chance.")
                            .font(.caption2).foregroundStyle(VColor.textTertiary)
                    }
                }
                .padding(VSpace.screenPadding)
            }
            .background(VColor.canvas)
            .navigationTitle("Behaviour impact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { entries = await model.journalEntries() }
        }
    }

    private func effectRow(_ e: BehaviorEffect) -> some View {
        let up = e.delta >= 0
        return VCard(padding: VSpace.md) {
            HStack(spacing: VSpace.md) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(VitalJournal.shortLabel(e.behavior)).font(.subheadline.weight(.semibold))
                        if e.significant { VPill(text: "Likely real", tint: VColor.hrv) }
                    }
                    Text("\(e.nWith) days with · \(e.nWithout) without").font(.caption2).foregroundStyle(VColor.textTertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text((up ? "+" : "−") + fmt(abs(e.delta)) + outcome.unit)
                        .font(VFont.statSmall).monospacedDigit()
                        .foregroundStyle(up ? VColor.recoveryHigh : VColor.recoveryLow)
                    Text("\(fmt(e.meanWith)) vs \(fmt(e.meanWithout))").font(.caption2).foregroundStyle(VColor.textTertiary).monospacedDigit()
                }
            }
        }
    }

    private func fmt(_ v: Double) -> String { outcome == .sleep ? String(format: "%.1f", v) : "\(Int(v.rounded()))" }
}
