//
//  SettingsScreen.swift
//  Tailspot
//
//  Organised into three sections:
//    SPOTTER   — handle claim (the only real identity setting; everything
//                else that once lived here was a fake affordance and has
//                been removed — see git history for the inventory).
//    REMINDERS — the streak-protection mute toggle (StreakReminders.swift),
//                with an honest permission-denied state that routes to iOS
//                Settings and heals on return.
//    ABOUT     — legal links (Privacy Policy, Terms, Attributions —
//                ODbL attribution for adsb.lol data is a licence
//                obligation), data-source credits, plus the tap-to-copy
//                version footer.
//

import SwiftUI
import SwiftData
import UserNotifications
import os

struct SettingsScreen: View {
    @AppStorage(SpotterHandle.storageKey) private var handle: String = SpotterHandle.defaultPlaceholder
    /// Streak-protection reminders (default ON; muting cancels any pending
    /// nudge on the next sync below). Key shared with StreakReminderCenter.
    @AppStorage(StreakReminders.enabledKey) private var streakRemindersEnabled = true

    @State private var handleDraft: String = ""
    @State private var handleTakenError: String? = nil
    @State private var isSavingHandle = false
    @State private var savedHandleSuccess: String? = nil   // brief "claimed" confirmation
    /// System notification permission, re-read on foreground so granting in
    /// iOS Settings heals the row without a relaunch.
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    private let accountClient = TailspotAccountClient()

    #if DEBUG
    /// Snapshot seam — the visual-pass harness can't drive the real
    /// notification-settings read, so it forces the row state here.
    /// nil (production) = live status.
    var _notifStatusOverride: UNAuthorizationStatus? = nil
    #endif

    private var notifDenied: Bool { notifStatus == .denied }

    /// True when the draft differs from the saved handle and is non-empty.
    private var isDirty: Bool {
        let t = handleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t != handle
    }

    var body: some View {
        List {

            // MARK: SPOTTER

            Section {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text("Handle")
                        Spacer()
                        Text("@")
                            .foregroundStyle(Brand.Color.textTertiary)
                        TextField("handle", text: $handleDraft)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(Brand.Font.mono(size: 17, relativeTo: .body))
                            .accessibilityLabel("Handle")
                            .onChange(of: handleDraft) { _, _ in
                                handleTakenError = nil
                                savedHandleSuccess = nil
                            }
                            .onSubmit { Task { await saveHandle() } }
                        if isSavingHandle {
                            ProgressView()
                                .scaleEffect(0.75)
                                .tint(Brand.Color.cyan)
                        }
                    }

                    // Inline error (409 taken) — shown below the field.
                    if let takenMsg = handleTakenError {
                        Label(takenMsg, systemImage: "exclamationmark.circle.fill")
                            .font(Brand.Font.caption)
                            .foregroundStyle(Brand.Color.alertCaution)
                            .padding(.top, 6)
                    }

                    // Transient success confirmation — clears automatically.
                    if let successMsg = savedHandleSuccess {
                        Label(successMsg, systemImage: "checkmark.circle.fill")
                            .font(Brand.Font.caption)
                            .foregroundStyle(Brand.Color.alertNormal)
                            .padding(.top, 6)
                    }
                }

                // Explicit Save / Claim button — disabled while no change or invalid.
                // Complements onSubmit (Return key) so the user always has a
                // visible affordance, especially on external keyboards where Return
                // focus is not obvious.
                Button {
                    Task { await saveHandle() }
                } label: {
                    HStack {
                        Spacer()
                        if isSavingHandle {
                            // Match the button's dark foreground (bgPrimary on
                            // cyan), not white — higher contrast on the cyan fill.
                            ProgressView().scaleEffect(0.85).tint(Brand.Color.bgPrimary)
                        } else {
                            Text("Save handle")
                                .font(Brand.Font.mono(size: 15, weight: .bold, relativeTo: .subheadline))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .background(isDirty ? Brand.Color.cyan : Brand.Color.bgElevated,
                                in: .rect(cornerRadius: Brand.Radius.row))
                    .foregroundStyle(isDirty ? Brand.Color.bgPrimary : Brand.Color.textTertiary)
                    // The filled capsule renders ~35 pt; the frame carries
                    // the 44 pt hit target without inflating the row visual.
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isDirty || isSavingHandle)
                .animation(.easeInOut(duration: 0.15), value: isDirty)
                // The button draws its own fill; clear the row so the idle
                // (bgElevated) state doesn't vanish into the section row color.
                .listRowBackground(Color.clear)

            } header: {
                Text("SPOTTER")
                    .font(Brand.Font.mono(size: 10, weight: .semibold, relativeTo: .caption2))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textTertiary)
                    .textCase(nil)
            } footer: {
                Text("Your handle is the only thing visible on the leaderboard. Claim it to reserve your spot.")
            }
            .listRowBackground(Brand.Color.bgElevated)

            // MARK: REMINDERS

            Section {
                Toggle(isOn: $streakRemindersEnabled) {
                    Text("Streak protection")
                        .foregroundStyle(notifDenied
                                         ? Brand.Color.textTertiary
                                         : Brand.Color.textPrimary)
                }
                .tint(Brand.Color.cyan)
                // Denied → the toggle alone goes inert (`.disabled` on the
                // whole row would also kill the recovery path below).
                .disabled(notifDenied)
                if notifDenied {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack {
                            Text("Open Settings")
                                .foregroundStyle(Brand.Color.textPrimary)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Brand.Color.textTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the Settings app")
                }
            } header: {
                Text("REMINDERS")
                    .font(Brand.Font.mono(size: 10, weight: .semibold, relativeTo: .caption2))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textTertiary)
                    .textCase(nil)
            } footer: {
                Text(notifDenied
                     ? "Notifications are off for Tailspot in iOS Settings. Allow them there to get streak nudges."
                     : "Get notified if your streak is at risk.")
            }
            .listRowBackground(Brand.Color.bgElevated)

            // MARK: ABOUT

            Section {
                // Legal links — open URLs in Safari.
                // Attributions row is REQUIRED to satisfy the ODbL licence
                // obligation for adsb.lol data; do not remove.
                legalLink(label: "Privacy Policy",
                          url: URL(string: "https://tailspot.app/privacy.html")!)
                legalLink(label: "Terms of Use",
                          url: URL(string: "https://tailspot.app/terms.html")!)
                legalLink(label: "Attributions",
                          url: URL(string: "https://tailspot.app/attributions.html")!)

                LabeledContent("Live aircraft data", value: "adsb.lol")
                LabeledContent("Photos", value: "Planespotters.net")

            } header: {
                Text("ABOUT")
                    .font(Brand.Font.mono(size: 10, weight: .semibold, relativeTo: .caption2))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textTertiary)
                    .textCase(nil)
            } footer: {
                // Version/build footer — tester-visible, tap-to-copy so bug
                // reports can paste an exact identifier.
                versionFooter
            }
            .listRowBackground(Brand.Color.bgElevated)
        }
        .listStyle(.insetGrouped)
        // Brand the list like SetsScreen/SetDetailView — without this the
        // List renders system grouped chrome, which flips white in light
        // mode against the fixed dark Brand palette.
        .scrollContentBackground(.hidden)
        .background(Brand.Color.bgPrimary.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        // Prefill only a genuinely claimed handle. For an unclaimed user the
        // stored value is still the "spotter_42" placeholder — prefilling it
        // as the field's VALUE reads as "your handle is spotter_42", the same
        // display-as-if-claimed leak the Profile header had. Empty draft →
        // the field shows its "handle" prompt instead.
        .onAppear {
            handleDraft = AnalyticsIdentity.isClaimedHandle(
                handle, placeholder: SpotterHandle.defaultPlaceholder
            ) ? handle : ""
        }
        .task { await refreshNotifStatus() }
        // Heal-on-return: the user goes to iOS Settings from the denied
        // state, allows notifications, comes back — the row un-dims on this
        // re-read, no relaunch needed.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await refreshNotifStatus() }
            }
        }
        .onChange(of: streakRemindersEnabled) { _, enabled in
            Task { @MainActor in
                // Toggling ON before the system prompt ever fired IS the
                // contextual ask for a user who found the setting first —
                // it latches the one-shot so the in-camera pre-prompt
                // never re-asks.
                if enabled,
                   await StreakReminderCenter.shared.authorizationStatus() == .notDetermined {
                    _ = await StreakReminderCenter.shared.requestPermission()
                    await refreshNotifStatus()
                }
                // Re-plan under the new setting: OFF cancels any pending
                // nudge, ON schedules if a streak is live.
                await StreakReminderCenter.shared.sync(context: modelContext)
            }
        }
    }

    /// Re-read the system permission (or the snapshot harness override).
    private func refreshNotifStatus() async {
        #if DEBUG
        if let override = _notifStatusOverride {
            notifStatus = override
            return
        }
        #endif
        notifStatus = await StreakReminderCenter.shared.authorizationStatus()
    }

    // MARK: - Handle claim

    /// Send the current `handleDraft` to the backend. On success persists
    /// locally and shows a brief confirmation. On 409 shows an inline
    /// "taken" error. Non-handle-taken errors are logged and persisted
    /// locally anyway (backend claim can be retried on next launch).
    private func saveHandle() async {
        let trimmed = handleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == handleDraft,   // already trimmed — don't re-trim mid-type
              !trimmed.isEmpty else { return }
        isSavingHandle = true
        defer { isSavingHandle = false }
        do {
            let deviceId = try await accountClient.ensureRegistered()
            try await accountClient.claimHandle(trimmed)
            handle = trimmed
            // Record the backend confirmation so HandleSyncer treats this
            // handle as already-synced and won't redundantly re-claim it.
            UserDefaults.standard.set(trimmed, forKey: SpotterHandle.confirmedKey)
            handleTakenError = nil
            savedHandleSuccess = "@\(trimmed) claimed"
            // Identify to the canonical server device id (established by
            // `ensureRegistered()` above) and `$set` the handle in ONE call, so
            // SDK events, session replay, and the handle all resolve to a single
            // canonical person. See AnalyticsIdentity.
            Analytics.identify(deviceId, handle: trimmed)
            Analytics.capture("handle_claimed", ["result": .string("success")])
            // Stop the spinner BEFORE the auto-clear sleep — the deferred
            // reset only fires at function exit, which would otherwise keep
            // the Save button spinning/disabled for the whole 3 s.
            isSavingHandle = false
            // Auto-clear the success state after 3 s.
            try? await Task.sleep(for: .seconds(3))
            if savedHandleSuccess == "@\(trimmed) claimed" {
                savedHandleSuccess = nil
            }
        } catch AccountError.handleTaken {
            handleTakenError = "@\(trimmed) is already taken"
            Analytics.capture("handle_claimed", ["result": .string("taken")])
        } catch AccountError.handleNotAllowed {
            // Server validation / profanity rejection (422) — terminal for
            // this handle; never persist it locally (see OnboardingFlow).
            handleTakenError = "@\(trimmed) isn't allowed"
            Analytics.capture("handle_claimed", ["result": .string("not_allowed")])
        } catch {
            Log.ui.error("Settings: handle claim failed (non-fatal): \(error, privacy: .public)")
            handle = trimmed
            handleTakenError = nil
        }
    }

    // MARK: - Legal link row

    @ViewBuilder
    private func legalLink(label: String, url: URL) -> some View {
        Button {
            UIApplication.shared.open(url)
        } label: {
            HStack {
                // Brand token, not Color.primary — the row background is the
                // fixed dark palette, so a semantic system color could render
                // near-black (invisible) if the environment ever reported light.
                Text(label)
                    .foregroundStyle(Brand.Color.textPrimary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Brand.Color.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        // The glyph is hidden above, so the "leaves the app" cue it carries
        // visually comes through here instead.
        .accessibilityHint("Opens in browser")
    }

    // MARK: - Version footer

    /// "Tailspot 0.1.0 (build N) · tap to copy". Tap copies the same
    /// string to the clipboard so a tester reporting a bug can paste
    /// it verbatim into a message — no "what version are you on?"
    /// back-and-forth.
    private var versionFooter: some View {
        Button {
            UIPasteboard.general.string = Bundle.main.tailspotVersionLine
            // Light haptic confirms the copy without yanking focus.
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        } label: {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(Bundle.main.tailspotVersionLine)
                    .font(Brand.Font.mono(size: 11, weight: .regular, relativeTo: .caption2))
                    .foregroundStyle(Brand.Color.textTertiary)
                // Full textTertiary, no extra opacity — tertiary × 0.6 fell
                // below readable contrast for an interactive hint.
                Text(" · tap to copy")
                    .font(Brand.Font.mono(size: 11, weight: .regular, relativeTo: .caption2))
                    .foregroundStyle(Brand.Color.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bundle version helpers

private extension Bundle {
    var shortVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }
    var buildNumber: String {
        (object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "—"
    }
    /// Combined "Tailspot X.Y.Z (build N)" string — used by the
    /// Settings footer for both display and clipboard payload.
    var tailspotVersionLine: String {
        "Tailspot \(shortVersion) (build \(buildNumber))"
    }
}

#Preview {
    NavigationStack { SettingsScreen() }
}
