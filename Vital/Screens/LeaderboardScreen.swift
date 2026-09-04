import SwiftUI

/// Friends leaderboard. Cards arrive as `vital://` links tapped from iMessage (or pasted codes); you share
/// yours from here with only the fields you tick. No server anywhere.
struct LeaderboardScreen: View {
    @EnvironmentObject private var model: VitalModel
    @EnvironmentObject private var friends: FriendsStore
    @State private var category: LeaderCategory = .recovery
    @State private var showShareSetup = false
    @State private var showPaste = false
    @State private var pasted = ""
    @State private var pasteError: String?

    private var me: FriendCard { model.myCard() }

    var body: some View {
        VScreen(title: "Friends") {
            Picker("Category", selection: $category) {
                ForEach(LeaderCategory.allCases) { c in Text(c.label).tag(c) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            board

            HStack(spacing: VSpace.md) {
                ShareLink(item: me.link() ?? URL(string: "vital://friend")!,
                          subject: Text("My Vital stats"),
                          message: Text(me.summaryText())) {
                    Label("Share my stats", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).tint(VColor.hrv)
                Button { showPaste = true } label: {
                    Label("Add friend", systemImage: "person.badge.plus").frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            }
            .font(.headline)

            Button { showShareSetup = true } label: {
                Label("What I share: \(sharedSummary)", systemImage: "lock.shield")
                    .font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain).foregroundStyle(VColor.textSecondary)

            Text("Send the link in your group chat; when a friend taps it, Vital files their card. Each new card from the same name replaces the last, so the board always shows everyone's latest day.")
                .font(.caption2).foregroundStyle(VColor.textTertiary)
        }
        .toolbar { SettingsToolbarButton() }
        .sheet(isPresented: $showShareSetup) { ShareSetupSheet() }
        .alert("Add a friend's card", isPresented: $showPaste) {
            TextField("Paste their vital:// link or code", text: $pasted)
            Button("Add") {
                if let card = FriendCard.decode(code: pasted) { friends.upsert(card); pasted = ""; pasteError = nil }
                else { pasteError = "That didn't look like a Vital card." }
            }
            Button("Cancel", role: .cancel) { pasted = "" }
        } message: { Text(pasteError ?? "Or just tap the link they sent — it opens here automatically.") }
    }

    private var sharedSummary: String {
        let inc = ShareFields.included
        return inc.isEmpty ? "nothing yet" : ShareFields.all.filter(inc.contains).map { $0.capitalized }.joined(separator: ", ")
    }

    private var board: some View {
        let entries = ([me] + friends.friends).compactMap { c -> (FriendCard, Double)? in
            guard let v = category.value(c) else { return nil }
            return (c, v)
        }.sorted { category.higherIsBetter ? $0.1 > $1.1 : $0.1 < $1.1 }
        return VCard {
            VStack(alignment: .leading, spacing: VSpace.md) {
                VCardHeader(title: category.label, subtitle: "\(entries.count) on the board", tint: VColor.hrv, systemImage: "trophy.fill")
                if entries.isEmpty {
                    VEmpty(systemImage: "person.2", title: "Nobody on the board yet",
                           message: "Share your stats and add friends' cards to start comparing.")
                } else {
                    ForEach(Array(entries.enumerated()), id: \.element.0.id) { i, e in
                        HStack(spacing: VSpace.md) {
                            Text("\(i + 1)").font(VFont.statSmall).monospacedDigit()
                                .foregroundStyle(i == 0 ? VColor.recoveryMid : VColor.textTertiary).frame(width: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.0.id == me.id ? "You" : e.0.name).font(.subheadline.weight(.semibold))
                                Text(e.0.dayKey.map(VFormat.dayLabel) ?? "—").font(.caption2).foregroundStyle(VColor.textTertiary)
                            }
                            Spacer()
                            Text(category.format(e.1)).font(VFont.statSmall).monospacedDigit()
                                .foregroundStyle(category == .recovery || category == .weekRecovery ? VColor.recovery(e.1) : VColor.textPrimary)
                        }
                        .padding(.vertical, 4)
                        .contextMenu {
                            if e.0.id != me.id { Button("Remove \(e.0.name)", role: .destructive) { friends.remove(e.0) } }
                        }
                        if i < entries.count - 1 { Divider().overlay(VColor.hairline) }
                    }
                }
            }
        }
    }
}

/// Pick a display name and which fields ride in your card.
struct ShareSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ShareFields.name
    @State private var included = ShareFields.included

    private let labels: [(String, String)] = [
        ("recovery", "Recovery"), ("strain", "Strain"), ("sleep", "Sleep performance"),
        ("hrv", "HRV"), ("rhr", "Resting heart rate"), ("week", "7-day averages"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Name on the board") {
                    TextField("Your name", text: $name)
                }
                Section {
                    ForEach(labels, id: \.0) { key, label in
                        Toggle(label, isOn: Binding(
                            get: { included.contains(key) },
                            set: { on in if on { included.insert(key) } else { included.remove(key) } }))
                    }
                } header: { Text("Included in my card") } footer: {
                    Text("Only ticked fields leave your phone, and only when you tap Share.")
                }
            }
            .scrollContentBackground(.hidden).background(VColor.canvas)
            .navigationTitle("Sharing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { ShareFields.name = name; ShareFields.included = included; dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Toolbar entry to the leaderboard, used on Today and Trends.
struct FriendsToolbarButton: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink { LeaderboardScreen() } label: { Image(systemName: "person.2") }
        }
    }
}
