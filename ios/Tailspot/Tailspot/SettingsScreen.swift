//
//  SettingsScreen.swift
//  Tailspot
//
//  Organised into three sections in order:
//    SPOTTER  — handle claim (the only real identity setting)
//    APP      — nothing real to show yet; removed vestigial toggles:
//                 • "Public hangar" was cut from beta scope — the
//                   tailspot.profile.public key is still written during
//                   onboarding but the toggle here controlled nothing
//                   server-side; revive when backend public-hangar
//                   endpoint ships (PLAN §9 #2).
//                 • "Rare-aircraft alerts" toggle (tailspot.notif.rare)
//                   never wired to push infrastructure; honest coming-soon
//                   state is in NotificationsScreen — remove here to avoid
//                   a fake affordance (PLAN §9 #2).
//                 • Playback rows (Source / Autocatch hold / Visibility cap)
//                   were display-only labels, not real settings — source
//                   toggle lives in the debug overlay, the others are
//                   in-code constants. Removed to cut clutter.
//    ABOUT    — legal links (Privacy Policy, Terms, Attributions —
//               ODbL attribution is a licence obligation), data-source
//               credit, plus the tap-to-copy version footer.
//

import SwiftUI
import os

struct SettingsScreen: View {
    @AppStorage(SpotterHandle.storageKey) private var handle: String = SpotterHandle.defaultPlaceholder

    @State private var handleDraft: String = ""
    @State private var handleTakenError: String? = nil
    @State private var isSavingHandle = false
    @State private var savedHandleSuccess: String? = nil   // brief "claimed" confirmation
    private let accountClient = TailspotAccountClient()

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
                            .font(Brand.Font.mono(size: 17))
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
                                .font(Brand.Font.mono(size: 15, weight: .bold))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .background(isDirty ? Brand.Color.cyan : Brand.Color.bgElevated,
                                in: .rect(cornerRadius: 10))
                    .foregroundStyle(isDirty ? Brand.Color.bgPrimary : Brand.Color.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(!isDirty || isSavingHandle)
                .animation(.easeInOut(duration: 0.15), value: isDirty)

            } header: {
                Text("SPOTTER")
                    .font(Brand.Font.mono(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textTertiary)
                    .textCase(nil)
            } footer: {
                Text("Your handle is the only thing visible on the leaderboard. Claim it to reserve your spot.")
            }

            // MARK: ABOUT

            Section {
                // Legal links — open URLs in Safari.
                // Attributions row is REQUIRED to satisfy the ODbL licence
                // obligation for OpenSky data; do not remove.
                legalLink(label: "Privacy Policy",
                          url: URL(string: "https://tailspot.app/privacy.html")!)
                legalLink(label: "Terms of Use",
                          url: URL(string: "https://tailspot.app/terms.html")!)
                legalLink(label: "Attributions",
                          url: URL(string: "https://tailspot.app/attributions.html")!)

                LabeledContent("Data source", value: "OpenSky Network")
                LabeledContent("Photos", value: "Planespotters.net")

            } header: {
                Text("ABOUT")
                    .font(Brand.Font.mono(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textTertiary)
                    .textCase(nil)
            } footer: {
                // Version/build footer — tester-visible, tap-to-copy so bug
                // reports can paste an exact identifier.
                versionFooter
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { handleDraft = handle }
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
                Text(label)
                    .foregroundStyle(Color.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Brand.Color.textTertiary)
            }
        }
        .buttonStyle(.plain)
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
                    .font(Brand.Font.mono(size: 11, weight: .regular))
                    .foregroundStyle(Brand.Color.textTertiary)
                Text(" · tap to copy")
                    .font(Brand.Font.mono(size: 11, weight: .regular))
                    .foregroundStyle(Brand.Color.textTertiary.opacity(0.6))
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
