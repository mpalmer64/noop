# Vital

A second iOS app in this fork (branch `max`) with its own SwiftUI interface over NOOP's unchanged
collection layer, store, and scoring engine. Fork-local; not for upstream.

## What it reuses, and how

| Layer | Source | How Vital gets it |
|---|---|---|
| BLE + offload | `Strand/BLE`, `Strand/Collect` | Compiled straight from the shared tree by the `Vital` target in `project.yml` (WHOOP path only; non-WHOOP live sources excluded). |
| Read model + scoring | `Strand/Data/Repository.swift`, `IntelligenceEngine.swift`, `Profile.swift` | Same. This is what makes Vital's numbers byte-identical to NOOP's. |
| Packages | WhoopProtocol, WhoopStore, StrandAnalytics, StrandImport, OuraProtocol, ZIPFoundation, StrandDesign | SPM deps. StrandDesign is linked only because `Repository` uses its `TrendPoint`; no Vital screen imports it. |
| App-layer symbols the above reference | — | `Vital/Compat/UpstreamShims.swift`. One file. When a rebase breaks the build with "cannot find X in scope", look here first. |

Rules: nothing under `Packages/`, `Strand/`, `StrandiOS*` is edited. The only shared file Vital touches is
`project.yml`, one contiguous block (`Vital` + `VitalWidgets`). No NOOP views or design tokens in `Vital/`.

## Layout

```
Vital/
  App/        VitalApp (@main), VitalRootView (tabs), VitalAppearance
  Model/      VitalModel — the only object views talk to (live / sync / derived channels), VitalNotifications
  Screens/    NowScreen, TodayScreen, SleepScreen, TrendsScreen, SettingsScreen
  Design/     VColor / VFont / VSpace / VFormat tokens; VCard, VRing, VScoreRing, VStatTile, VSparkline, VHypnogram…
  Shared/     VitalSnapshot — App Group glance, compiled into the app and the widget
  Compat/     UpstreamShims.swift
  Resources/  Assets.xcassets (AppIcon), generated Info.plist / entitlements
  Seed/       whoop_export.zip — personal data, excluded via .git/info/exclude, NOT committed
VitalWidgets/ WidgetKit extension (small/medium/lock-screen), reads VitalSnapshot
```

## Data flow

- **Live**: `LiveState.heartRate` → median-smoothed `VitalModel.bpm` (port of `AppModel.ingestHR`). The
  realtime feed is requested while the Now screen is showing and re-armed after each bond.
- **Sync**: `LiveState.lastSyncedAt` (debounced 2 s) → `repo.refresh` → `IntelligenceEngine.analyzeRecent`
  → `repo.refresh` → derived recompute. Same trigger NOOP uses.
- **Derived**: recomputed after refresh and on a 60 s tick, never per render. Anchor day resolution is
  `Repository.widgetAnchor`; Rest comes from the `sleep_performance` metric series like the NOOP widget.
- **Seed**: first launch imports the bundled export under device id `my-whoop` (same id as the strap), so
  imported and on-device days merge as one history. Settings can import another export.
- **Widget**: `VitalSnapshot.publish` from the derived tick; WidgetKit reload only when a rendered field
  changed. App Group `group.$(BUNDLE_ID_PREFIX).vital`.

## Build / run

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodegen generate
# generic compile check
xcodebuild -project Strand.xcodeproj -scheme Vital -destination 'generic/platform=iOS' -allowProvisioningUpdates build
# phone (unlocked, trusted)
xcodebuild -project Strand.xcodeproj -scheme Vital -destination 'id=<UDID>' -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID> ~/Library/Developer/Xcode/DerivedData/Strand-*/Build/Products/Debug-iphoneos/Vital.app
xcrun devicectl device process launch --terminate-existing --device <UDID> com.maxpalmer.vital
```

Headless screenshots on a simulator: `SIMCTL_CHILD_VITAL_TAB=today|sleep|trends|settings xcrun simctl launch …`
preselects a tab (debug-only env var, inert otherwise).

## Upstream sync

```bash
git fetch upstream && git checkout main && git merge --ff-only upstream/main
git checkout max && git rebase main
xcodegen generate && xcodebuild … -scheme NOOPiOS … build   # baseline must still pass
xcodebuild … -scheme Vital … build                          # fix shims if it fails
git push --force-with-lease origin max
```

## Licence

NOOP is PolyForm Noncommercial 1.0.0 (Required Notice: Copyright 2026 NoopApp). Vital is a personal,
non-commercial build; it may be shared privately with the notices intact and may never be sold or put on an
app store. See `LICENSE`, `NOTICE`, `DISCLAIMER.md`, `ATTRIBUTION.md` at the repo root and the in-app
"Licence & attribution" screen.
