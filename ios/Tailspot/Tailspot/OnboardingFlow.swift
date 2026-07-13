//
//  OnboardingFlow.swift
//  Tailspot
//
//  Three-step onboarding presented before the AR view becomes
//  reachable on first launch:
//
//   1. Welcome — brand lockup + value pitch + CTA.
//   2. Permissions — what we'll ask for and why. iOS prompts fire
//      on advance, not at the end of onboarding (testers reported
//      the end-of-flow prompt timing as confusing).
//   3. Pick a handle — seeds the public leaderboard identity.
//
//  Completion latches in @AppStorage so subsequent launches skip
//  the flow entirely.
//

import SwiftUI
import SwiftData
import AVFoundation
import CoreLocation   // CLAuthorizationStatus cases in the permission-outcome hook
import os

// MARK: - Gate

enum Onboarding {
    static let storageKey = "tailspot.onboarding.completed"
}

/// Wraps `ContentView` so onboarding is presented on first launch
/// and `ContentView` only takes over once it completes. Lives in
/// `TailspotApp.swift` (via this view) so the root tree is unchanged.
///
/// Critical: ContentView is NOT mounted while onboarding is on
/// screen. Mounting it (even at opacity 0) fires its `.task`
/// blocks, which kick off camera / location / ADS-B requests —
/// system permission alerts would pop over the Welcome step and
/// OpenSky credits would burn before the user finished onboarding.
/// The conditional below makes the swap exclusive.
struct RootView: View {
    @AppStorage(Onboarding.storageKey) private var completed: Bool = false
    @Environment(\.modelContext) private var modelContext
    /// Existing-user migration. When the Hangar already has catches,
    /// the user predates onboarding — flip them through automatically
    /// so they aren't walled out of the AR view by a new launch screen.
    @Query private var existingCatches: [Catch]
    @State private var didMigrate = false

    /// UI-test hook: launch the app straight into the Hangar (skipping
    /// onboarding + the camera/permission AR flow the simulator can't run) so
    /// the Sets-navigation regression test can tap through reliably. Gated on a
    /// launch argument that production never passes — see SetsNavigationUITests.
    private var uiTestHangar: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestHangar")
    }

    var body: some View {
        Group {
            if uiTestHangar {
                HangarView()
            } else if completed {
                ContentView()
            } else {
                OnboardingFlow {
                    completed = true
                }
            }
        }
        .task {
            guard !didMigrate else { return }
            didMigrate = true
            if uiTestHangar {
                // Seed one catch so the Hangar shows its segmented Sets browser
                // (the empty state hides it). icao24 only — the Sets list shows
                // every family regardless of catch contents.
                if existingCatches.isEmpty {
                    modelContext.insert(Catch(
                        icao24: "uitest",
                        callsign: "UAL1",
                        model: "737-800",
                        manufacturer: "BOEING",
                        operatorName: "United Airlines",
                        caughtAt: Date(timeIntervalSince1970: 1_716_000_000),
                        observerLat: 37.87, observerLon: -122.27,
                        slantDistanceMeters: 5000
                    ))
                    try? modelContext.save()
                }
                return
            }
            if !completed, !existingCatches.isEmpty {
                completed = true
            }
        }
    }
}

// MARK: - Flow

struct OnboardingFlow: View {
    let onFinish: () -> Void

    @State private var step: Int

    /// `initialStep` exists for the snapshot harness (render any step
    /// without tapping through) — production always starts at 0.
    init(onFinish: @escaping () -> Void, initialStep: Int = 0) {
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
    }
    @AppStorage(SpotterHandle.storageKey) private var handle: String = SpotterHandle.defaultPlaceholder
    @State private var draftHandle: String = ""
    /// Held as a @StateObject so its CLLocationManager delegate stays
    /// alive long enough for iOS to surface the prompt and receive the
    /// user's answer. Discarded when onboarding completes; ContentView
    /// then creates its own LocationManager.
    @StateObject private var locationForPermissions = LocationManager()
    @State private var permissionsRequested = false
    /// Latches the one-shot `permission_outcome` (location) event — the
    /// authorization status can re-publish without changing meaning.
    @State private var locationOutcomeReported = false
    /// Non-nil when the backend returned 409 (handle taken) during the
    /// last claim attempt.
    @State private var handleTakenError: String? = nil

    private let totalSteps = 4
    /// Outcome of the handle claim (success / offline_fallback), stashed so
    /// `onboarding_completed` can report it from the final (calibration) step.
    @State private var claimOutcome = "success"
    /// Latches once the live heading accuracy reads good (≤10°) during the
    /// calibration step — mirrors CompassCalibrationSheet's session latch.
    @State private var calibratedInFlow = false
    private let accountClient = TailspotAccountClient()

    /// Suggested handles offered in the handle step. Seeded with a LOCALLY
    /// randomized set so the chips are never the old deterministic four
    /// ("spotter_42", …) that every user collided on — then replaced by
    /// backend-verified-free suggestions once `loadSuggestions()` returns.
    /// Held in @State so the async load can update them; they stay fixed
    /// thereafter unless a claim comes back taken (then they refresh).
    @State private var handleSuggestions: [String] = HandleSuggestions.randomized(count: 4)
    /// Latches the one-time backend fetch so re-entering the handle step
    /// (e.g. via Back) doesn't reshuffle while the user is mid-thought.
    @State private var suggestionsLoaded = false

    var body: some View {
        ZStack {
            Brand.Color.bgPrimary.ignoresSafeArea()
            backdrop.ignoresSafeArea()
            VStack(spacing: 16) {
                // Scroll the step content so it never truncates or clips on
                // shorter iPhones (e.g. SE / 8, 667pt) — the old fixed VStack
                // compressed the title to one line ("Spot every plane ove…",
                // issue #36). The footer button stays pinned below.
                ScrollView(.vertical, showsIndicators: false) {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 80)
                }
                footer
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
        // Activation funnel: record every step the user actually SEES, so
        // PostHog can show where the ~36 openers → 5 catchers leak starts
        // (nothing between "Application Opened" and first_plane_catch was
        // instrumented before). onAppear covers step 0; onChange the rest.
        .onAppear { ActivationTelemetry.fireStepViewed(step: step) }
        .onChange(of: step) { _, newStep in
            ActivationTelemetry.fireStepViewed(step: newStep)
        }
        // Location permission outcome. The camera outcome comes straight
        // from the requestAccess callback; location only surfaces through
        // the (throwaway) manager's published authorization status.
        .onChange(of: locationForPermissions.authorizationStatus) { _, status in
            guard permissionsRequested, !locationOutcomeReported,
                  status != .notDetermined else { return }
            locationOutcomeReported = true
            let granted = status == .authorizedWhenInUse || status == .authorizedAlways
            ActivationTelemetry.firePermissionOutcome(permission: "location", granted: granted)
        }
    }

    #if DEBUG
    /// Snapshot-only mirror of `body` with the ScrollView flattened —
    /// ImageRenderer renders ScrollView content as empty (the same
    /// limitation CatchRevealView's `_snapshotScreen` works around).
    /// Production layout keeps the ScrollView for SE-height devices.
    @MainActor func _snapshotScreen(size: CGSize) -> some View {
        ZStack {
            Brand.Color.bgPrimary
            backdrop
            VStack(spacing: 16) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 80)
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
        .frame(width: size.width, height: size.height)
    }
    #endif

    private var backdrop: some View {
        ZStack {
            // Subtle cyan radial near the top.
            RadialGradient(
                gradient: Gradient(colors: [Brand.Color.cyan.opacity(0.08), .clear]),
                center: UnitPoint(x: 0.5, y: 0.25),
                startRadius: 0,
                endRadius: 360
            )
            // Magenta radial near the lower half — adds depth on
            // dark surfaces, mirrors the canvas backdrop.
            RadialGradient(
                gradient: Gradient(colors: [Brand.Color.alertAdvisory.opacity(0.06), .clear]),
                center: UnitPoint(x: 0.5, y: 0.75),
                startRadius: 0,
                endRadius: 320
            )
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcomeStep
        case 1: permissionsStep
        case 2: handleStep
        default: calibrationStep
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            lockup
            stepLabel("STEP 1 / 4")
            Text("Spot every plane overhead.")
                .brandDisplayFont()
                .foregroundStyle(Brand.Color.textPrimary)
                .multilineTextAlignment(.leading)
            Text("Point your phone at the sky. Tailspot uses live ADS-B data to identify the aircraft you're looking at, then lets you catch it to your Hangar.")
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)
            sampleCardHint
        }
    }

    private var sampleCardHint: some View {
        HStack {
            Spacer()
            CatchCardView(
                plane: .init(
                    callsign: "UAL248",
                    model: "Boeing 787-9",
                    carrier: "United Airlines",
                    rarity: .rare,
                    type: .wide,
                    altText: "FL370",
                    speedText: "478 kt",
                    distText: "12 km"
                ),
                size: .md,
                holoIntensity: 0.45,
                rotation: .degrees(-4)
            )
            Spacer()
        }
        .padding(.top, 18)
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepLabel("STEP 2 / 4 · PERMISSIONS")
            Text("Three things we need to read the sky.")
                .brandDisplayFont()
                .foregroundStyle(Brand.Color.textPrimary)
            VStack(spacing: 10) {
                permissionRow(glyph: "location.fill",  title: "Location, while in use",
                              body: "Match your viewing angle against live flight positions. Not retained as history.")
                permissionRow(glyph: "camera.fill",    title: "Camera",
                              body: "Used for AR overlay only. Tailspot never records or transmits the camera feed.")
                permissionRow(glyph: "gyroscope",      title: "Motion & orientation",
                              body: "Read which way you're aiming so the labels match the plane in view.")
            }
            .padding(.top, 4)
            Text("Tap below — iOS will ask for camera and location.")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textTertiary)
        }
    }

    private func permissionRow(glyph: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: glyph)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.Color.cyan)
                .frame(width: 28, height: 28)
                .background(Brand.Color.cyan.opacity(0.12), in: .rect(cornerRadius: Brand.Radius.chip))
                // The title restates the glyph; keep VoiceOver from
                // reading the raw SF Symbol name.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
                Text(body)
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: Brand.Radius.row))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Step 3: Handle

    private var handleStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepLabel("STEP 3 / 4 · PUBLIC HANDLE")
            Text("Pick a handle.")
                .brandDisplayFont()
                .foregroundStyle(Brand.Color.textPrimary)
            Text("Shown on the global leaderboard. Real name stays private.")
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)

            // Input row + inline availability pill.
            VStack(alignment: .leading, spacing: 6) {
                Text("HANDLE")
                    .font(Brand.Font.mono(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textTertiary)
                HStack {
                    Text("@")
                        .font(Brand.Font.mono(size: 22, weight: .bold))
                        .foregroundStyle(Brand.Color.textTertiary)
                        .accessibilityHidden(true)
                    TextField("spotter_42", text: $draftHandle)
                        .font(Brand.Font.mono(size: 22, weight: .bold))
                        .foregroundStyle(Brand.Color.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Handle")
                        .onChange(of: draftHandle) { _, _ in handleTakenError = nil }
                    if !draftHandle.isEmpty {
                        availabilityPill
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Brand.Color.bgElevated, in: .rect(cornerRadius: Brand.Radius.row))
                .overlay(
                    RoundedRectangle(cornerRadius: Brand.Radius.row)
                        .strokeBorder(
                            handleIsValid
                                ? Brand.Color.alertNormal.opacity(0.35)
                                : (draftHandle.isEmpty
                                   ? Color.clear
                                   : Brand.Color.alertCaution.opacity(0.45)),
                            lineWidth: 1
                        )
                )
                Text("Letters, numbers, underscores. 3–20 characters.")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textTertiary)
                if let takenMsg = handleTakenError {
                    Label(takenMsg, systemImage: "exclamationmark.circle.fill")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.alertCaution)
                }
            }

            // Suggestion chips.
            VStack(alignment: .leading, spacing: 8) {
                Text("SUGGESTIONS")
                    .font(Brand.Font.mono(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textTertiary)
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 8
                ) {
                    ForEach(handleSuggestions, id: \.self) { s in
                        Button {
                            draftHandle = s
                        } label: {
                            HStack(spacing: 2) {
                                Text("@")
                                    .foregroundStyle(Brand.Color.textTertiary)
                                Text(s)
                                    .foregroundStyle(Brand.Color.textPrimary)
                            }
                            .font(Brand.Font.mono(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Brand.Color.bgElevated, in: .rect(cornerRadius: Brand.Radius.row))
                            .overlay(
                                RoundedRectangle(cornerRadius: Brand.Radius.row)
                                    .strokeBorder(Brand.Color.cyan.opacity(0.20), lineWidth: 1)
                            )
                            // Visible chip stays ~36 pt; the frame grows the
                            // HIT region to the 44 pt HIG minimum.
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        // Replace the local randomized chips with backend-verified-free
        // suggestions the first time this step appears. Best-effort.
        .task { await loadSuggestions() }
    }

    // MARK: - Step 4: Compass calibration

    /// The compass step (design ref: design/screens/onboarding.jsx
    /// Variation A). Last on purpose: it needs location permission (heading
    /// updates) from step 2, and it's the hand-off into AR — the user walks
    /// in with a compass that points at the right plane. Skippable — the
    /// same coaching remains reachable later via the AR caution badge
    /// (CompassCalibrationSheet); a first run must never dead-end on a
    /// stubborn magnetometer.
    private var calibrationStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepLabel("FINAL STEP · COMPASS")
            Text(calibratedInFlow ? "Compass calibrated." : "Trace a figure-8 in the air.")
                .brandDisplayFont()
                .foregroundStyle(Brand.Color.textPrimary)
            Text("iPhone compasses drift near metal and buildings. A quick figure-8 motion calibrates yours, so labels point at the plane you're actually looking at.")
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)

            Figure8Animation()
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)

            // Live readout, mirroring CompassCalibrationSheet: watching the
            // ± number fall IS the feedback loop.
            HStack(spacing: 14) {
                Text("HDG")
                    .font(Brand.Font.mono(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textTertiary)
                Text(calibrationHeadingText)
                    .font(Brand.Font.mono(size: 15, weight: .bold))
                    .foregroundStyle(Brand.Color.textPrimary)
                Text(calibrationAccuracyText)
                    .font(Brand.Font.mono(size: 15, weight: .bold))
                    .foregroundStyle(calibratedInFlow
                                     ? Brand.Color.alertNormal
                                     : Brand.Color.alertCaution)
                Spacer()
                if calibratedInFlow {
                    Label("CALIBRATED", systemImage: "checkmark.circle.fill")
                        .font(Brand.Font.mono(size: 10, weight: .bold))
                        .tracking(1.0)
                        .foregroundStyle(Brand.Color.alertNormal)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Brand.Color.bgElevated, in: .rect(cornerRadius: Brand.Radius.row))
        }
        .onChange(of: locationForPermissions.headingAccuracy) { _, acc in
            guard let acc, acc >= 0, acc <= 10 else { return }
            calibratedInFlow = true
        }
    }

    private var calibrationHeadingText: String {
        guard let h = locationForPermissions.heading else { return "—" }
        return String(format: "%.0f°", h)
    }

    private var calibrationAccuracyText: String {
        guard let acc = locationForPermissions.headingAccuracy, acc >= 0 else { return "±—" }
        return String(format: "±%.0f°", acc)
    }

    /// Compact status pill rendered inside the handle field. Reads
    /// "● AVAILABLE" when the draft is valid, "● TOO SHORT" when
    /// length is wrong, "● BAD CHARS" when characters are invalid.
    /// This is LOCAL FORMAT validation only — "AVAILABLE" means the draft is a
    /// well-formed handle, not that the name is free. Real uniqueness is
    /// enforced at claim time (the backend 409 → inline "taken" error); the
    /// suggestion chips are separately pre-filtered to free names by the backend.
    private var availabilityPill: some View {
        let label: String = {
            let t = draftHandle.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count < 3 { return "TOO SHORT" }
            if t.count > 20 { return "TOO LONG" }
            return handleIsValid ? "AVAILABLE" : "BAD CHARS"
        }()
        let tint = handleIsValid ? Brand.Color.alertNormal : Brand.Color.alertCaution
        return HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label)
                .font(Brand.Font.mono(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: .capsule)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 14) {
            progressBar
            primaryButton
            if step > 0 {
                // textSecondary (not tertiary) — a primary navigation
                // affordance shouldn't sit at the lowest contrast tier;
                // the 44 pt frame gives it a full-height hit target.
                Button {
                    withAnimation { step -= 1 }
                } label: {
                    Text("Back")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Rectangle()
                    .fill(i <= step ? Brand.Color.cyan : Brand.Color.bgElevated)
                    .frame(maxWidth: .infinity)
                    .frame(height: 3)
                    .clipShape(Capsule())
            }
        }
    }

    /// On the calibration step the button is a quiet "skip" until the
    /// compass actually reads good — a bright cyan CTA would invite
    /// skipping the one step that makes labels point at the right plane
    /// (mock: onboarding.jsx Variation A's `subtle` footer).
    private var primaryIsSubtle: Bool { step == 3 && !calibratedInFlow }

    private var primaryButton: some View {
        Button {
            advance()
        } label: {
            HStack {
                Text(primaryButtonTitle)
                    .font(.system(size: 16, weight: .bold))
                if step < totalSteps - 1 {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(primaryIsSubtle ? Brand.Color.textSecondary : .black.opacity(0.88))
            .background(
                primaryIsSubtle ? Brand.Color.bgElevated : Brand.Color.cyan,
                in: .rect(cornerRadius: Brand.Radius.card)
            )
            .shadow(color: Brand.Color.cyan.opacity(primaryIsSubtle ? 0 : 0.30),
                    radius: 16, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(step == 2 && !handleIsValid)
        .opacity((step == 2 && !handleIsValid) ? 0.6 : 1)
    }

    private var primaryButtonTitle: String {
        switch step {
        case 0: return "Get started"
        case 1: return "Allow permissions"
        case 2: return "Claim handle"
        default: return calibratedInFlow ? "Start spotting" : "Skip · I'll do it later"
        }
    }

    /// Handle validation. Letters/digits/underscore, length 3-20.
    private var handleIsValid: Bool {
        let t = draftHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...20).contains(t.count) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return t.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func advance() {
        switch step {
        case 1:
            requestSystemPermissions()
            withAnimation { step += 1 }
        case 2:
            // Claim before advancing — a 409 shows the inline error and
            // keeps the user here; success/offline moves to calibration.
            let trimmed = draftHandle.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { await claimHandleIfNeeded(trimmed) }
        case totalSteps - 1:
            ActivationTelemetry.fireCompleted(
                claimResult: claimOutcome, calibrated: calibratedInFlow
            )
            onFinish()
        default:
            withAnimation { step += 1 }
        }
    }

    /// Attempt to claim `trimmed` on the backend. On success (or no backend
    /// conflict) persist locally and advance to the calibration step. On 409
    /// (taken), set `handleTakenError` so the UI shows an inline error and
    /// the user stays on the handle step.
    private func claimHandleIfNeeded(_ trimmed: String) async {
        // Already confirmed on the server (the user came Back from the
        // calibration step and advanced again) — no second network claim.
        if UserDefaults.standard.string(forKey: SpotterHandle.confirmedKey) == trimmed {
            withAnimation { step += 1 }
            return
        }
        do {
            let deviceId = try await accountClient.ensureRegistered()
            try await accountClient.claimHandle(trimmed)
            // Success — persist locally and record the backend confirmation so
            // HandleSyncer knows this handle is already on the server.
            handle = trimmed
            UserDefaults.standard.set(trimmed, forKey: SpotterHandle.confirmedKey)
            handleTakenError = nil
            // Identify to the canonical server device id (established by
            // `ensureRegistered()` above) and `$set` the handle in ONE call. For
            // a first-time user this is the SDK's first identify, so PostHog
            // aliases the prior anonymous activity into the server-id person —
            // one person, handle attached. See AnalyticsIdentity.
            Analytics.identify(deviceId, handle: trimmed)
            Analytics.capture("handle_claimed", ["result": .string("success")])
            claimOutcome = "success"
            withAnimation { step += 1 }
        } catch AccountError.handleTaken {
            handleTakenError = "@\(trimmed) is already taken. Try a different handle."
            Analytics.capture("handle_claimed", ["result": .string("taken")])
            // Offer a fresh set of verified-free chips so the user has a quick out.
            await refreshSuggestions()
        } catch {
            // Network/auth failure — persist locally anyway and move on.
            // The handle claim can be retried from Settings later.
            Log.ui.error("Onboarding: handle claim failed (non-fatal): \(error, privacy: .public)")
            handle = trimmed
            handleTakenError = nil
            claimOutcome = "offline_fallback"
            withAnimation { step += 1 }
        }
    }

    /// Fetch backend-verified-free suggestions once and replace the local
    /// randomized fallback. Best-effort: on any failure (offline, or the
    /// backend endpoint not yet deployed) we keep the randomized fallback, so
    /// the chips are never the old deterministic set regardless.
    private func loadSuggestions() async {
        guard !suggestionsLoaded else { return }
        suggestionsLoaded = true
        do {
            let fetched = try await accountClient.suggestHandles(count: 4)
            if !fetched.isEmpty { handleSuggestions = fetched }
        } catch {
            Log.ui.notice("Onboarding: suggestion fetch failed; keeping local fallback: \(error, privacy: .public)")
        }
    }

    /// Replace the chips with a fresh free set after a claim came back taken.
    /// Falls back to a new local randomized set if the backend is unreachable.
    private func refreshSuggestions() async {
        do {
            let fetched = try await accountClient.suggestHandles(count: 4)
            handleSuggestions = fetched.isEmpty ? HandleSuggestions.randomized(count: 4) : fetched
        } catch {
            handleSuggestions = HandleSuggestions.randomized(count: 4)
        }
    }

    /// Fire camera + location prompts when the user advances out of the
    /// permissions step. iOS surfaces them modally and queues automatically,
    /// so the user dismisses both before the next step appears. CMMotion
    /// doesn't gate on permission so there's no prompt for the motion row.
    private func requestSystemPermissions() {
        guard !permissionsRequested else { return }
        permissionsRequested = true
        // The callback runs on an arbitrary queue; Analytics.capture is
        // nonisolated + thread-safe (the PostHog SDK queues internally).
        AVCaptureDevice.requestAccess(for: .video) { granted in
            ActivationTelemetry.firePermissionOutcome(permission: "camera", granted: granted)
        }
        locationForPermissions.requestPermissionAndStart()
    }

    // MARK: - Bits

    private var lockup: some View {
        HStack(spacing: 10) {
            Image(systemName: "airplane")
                .font(.system(size: 22))
                .foregroundStyle(Brand.Color.cyan)
                .accessibilityHidden(true)
            Text("TAILSPOT")
                .font(Brand.Font.mono(size: 22, weight: .bold))
                .tracking(3)
                .foregroundStyle(Brand.Color.textPrimary)
        }
    }

    private func stepLabel(_ text: String) -> some View {
        Text(text)
            .font(Brand.Font.mono(size: 10, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(Brand.Color.cyan)
    }
}

// MARK: - Figure 8 animation

/// Animated cyan dot tracing a figure-8 path. Pure SwiftUI — no
/// CABasicAnimation needed; `TimelineView` ticks the dot's
/// parametric position every frame. Used by both the onboarding
/// calibration step and the in-app `CompassCalibrationSheet`.
/// Reduce Motion: a static path illustration — the dashed figure-8
/// with a steady dot, no TimelineView ticking.
struct Figure8Animation: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            canvas(dotPhase: .pi / 4)   // a static, clearly on-path dot
        } else {
            TimelineView(.animation(minimumInterval: 1.0/30.0)) { context in
                // Animated dot along the path. Period: 3.2s.
                let now = context.date.timeIntervalSinceReferenceDate
                let t = (now.truncatingRemainder(dividingBy: 3.2)) / 3.2 * .pi * 2
                canvas(dotPhase: t)
            }
        }
    }

    /// The figure-8 illustration at a given dot position (parametric
    /// angle 0…2π along the lemniscate).
    private func canvas(dotPhase: Double) -> some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let centerX = w / 2
            let centerY = h / 2
            let scale = min(w, h) * 0.36
            // Trace the underlying figure-8 (lemniscate-ish) as a
            // dashed reference path.
            var ref = Path()
            let steps = 120
            for i in 0...steps {
                let t = Double(i) / Double(steps) * .pi * 2
                let x = centerX + CGFloat(sin(t) * Double(scale))
                let y = centerY + CGFloat(sin(2 * t) * Double(scale * 0.5))
                if i == 0 { ref.move(to: .init(x: x, y: y)) }
                else { ref.addLine(to: .init(x: x, y: y)) }
            }
            ctx.stroke(
                ref,
                with: .color(Brand.Color.cyan.opacity(0.35)),
                style: .init(lineWidth: 1.4, dash: [3, 5])
            )
            let x = centerX + CGFloat(sin(dotPhase) * Double(scale))
            let y = centerY + CGFloat(sin(2 * dotPhase) * Double(scale * 0.5))
            let dot = Path(ellipseIn: CGRect(x: x - 6, y: y - 6, width: 12, height: 12))
            ctx.fill(dot, with: .color(Brand.Color.cyan))
        }
    }
}

#Preview {
    OnboardingFlow(onFinish: {})
}
