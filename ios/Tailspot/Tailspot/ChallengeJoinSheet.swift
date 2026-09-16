//
//  ChallengeJoinSheet.swift
//  Tailspot
//
//  Join a challenge (spec §4.3, the "Preflight"): either type a code, or
//  arrive with one (typed on the hub, or later from a tailspot.app/c/CODE
//  link) and see the preview — who, when, the rule in one card — then Join.
//  Terminal states replace the button (Full, Ended, Cancelled, Already in,
//  Not found, unavailable). A device without a handle claims one inline,
//  the same call Settings makes, so joining stays one screen.
//

import SwiftUI
import os

struct ChallengeJoinSheet: View {
    @Environment(ChallengesModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SpotterHandle.storageKey) private var handle: String = SpotterHandle.defaultPlaceholder

    /// How the code arrived, for `challenge_invite_opened` — "code_entry"
    /// or "universal_link".
    let via: String
    let onJoined: (ChallengeDetail) -> Void

    /// What the sheet is showing. Pure mapping from a preview lives in
    /// `Phase.from(preview:)` so the tests pin it.
    enum Phase: Equatable {
        case entry
        case lookingUp
        case preview(ChallengeInvitePreview, Terminal?)
        case failed(ChallengesError)

        /// Why the Join button is replaced, if it is.
        enum Terminal: Equatable {
            case alreadyIn, full, ended, cancelled
        }

        static func from(preview p: ChallengeInvitePreview) -> Phase {
            if p.alreadyIn { return .preview(p, .alreadyIn) }
            if p.canJoin { return .preview(p, nil) }
            switch p.reason {
            case "full": return .preview(p, .full)
            case "cancelled": return .preview(p, .cancelled)
            default: return .preview(p, .ended)
            }
        }
    }

    @State private var codeDraft: String
    @State private var codeHint: String?
    @State private var phase: Phase
    @State private var isJoining = false
    @State private var joinError: ChallengesError?

    // Inline handle claim
    @State private var handleDraft = ""
    @State private var handleError: String?
    @State private var isClaiming = false
    @State private var claimedInline = false
    private let accountClient = TailspotAccountClient()

    init(code: String?, via: String, onJoined: @escaping (ChallengeDetail) -> Void,
         _debugPhase: Phase? = nil) {
        self.via = via
        self.onJoined = onJoined
        _codeDraft = State(initialValue: code ?? "")
        if let _debugPhase {
            _phase = State(initialValue: _debugPhase)
        } else {
            _phase = State(initialValue: code == nil ? .entry : .lookingUp)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                GlassEffectContainer {
                    VStack(alignment: .leading, spacing: 16) {
                        switch phase {
                        case .entry: entry
                        case .lookingUp: lookingUp
                        case .preview(let p, let terminal): preview(p, terminal: terminal)
                        case .failed(let e): failed(e)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(ChallengeBackdrop())
            .navigationTitle("Join a challenge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                if case .lookingUp = phase, let code = InviteCode.normalize(codeDraft) {
                    await lookUp(code)
                } else if case .lookingUp = phase {
                    phase = .failed(.notFound)
                }
            }
        }
    }

    // MARK: Entry

    private var entry: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Got a code?")
                .brandDisplayFont()
                .foregroundStyle(Brand.Color.textPrimary)
            Text("It's the eight characters at the end of the link a friend sent you, like tailspot.app/c/K7M4QD2X.")
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)
            TextField("K7M4QD2X", text: $codeDraft)
                .font(Brand.Font.mono(size: 22, weight: .bold, relativeTo: .title3))
                .foregroundStyle(Brand.Color.cyan)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .multilineTextAlignment(.center)
                .padding(.vertical, 12)
                .background(Brand.Color.bgPrimary.opacity(0.6), in: .rect(cornerRadius: Brand.Radius.row))
                .accessibilityLabel("Invite code")
                .onChange(of: codeDraft) { _, new in
                    codeHint = nil
                    let upper = new.uppercased()
                    if upper != new { codeDraft = upper }
                }
                .onSubmit { Task { await submitCode() } }
            if let codeHint {
                Text(codeHint)
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.alertCaution)
            }
            Button { Task { await submitCode() } } label: {
                primaryLabel("Look up", enabled: !codeDraft.isEmpty)
            }
            .buttonStyle(.plain)
            .disabled(codeDraft.isEmpty)
        }
        .padding(18)
        .glassEffect(ChallengeStyle.glass, in: .rect(cornerRadius: Brand.Radius.card))
    }

    private func submitCode() async {
        guard let code = InviteCode.normalize(codeDraft) else {
            codeHint = "Codes are 8 letters and numbers, and never use 0, 1, I, L or O."
            return
        }
        phase = .lookingUp
        await lookUp(code)
    }

    private var lookingUp: some View {
        HStack {
            Spacer()
            ProgressView().tint(Brand.Color.cyan)
            Spacer()
        }
        .padding(.top, 60)
        .accessibilityLabel("Looking up the challenge")
    }

    private func lookUp(_ code: String) async {
        do {
            let p = try await model.invitePreview(code: code)
            phase = Phase.from(preview: p)
            let status: String = {
                if case .preview(_, let t) = phase, let t {
                    switch t {
                    case .alreadyIn: return "already_in"
                    case .full: return "full"
                    case .ended: return "ended"
                    case .cancelled: return "cancelled"
                    }
                }
                return "open"
            }()
            Analytics.capture("challenge_invite_opened", [
                "challenge_id": .string(p.challenge.id),
                "via": .string(via),
                "status": .string(status),
            ])
        } catch let e as ChallengesError {
            phase = .failed(e)
            Analytics.capture("challenge_invite_opened", [
                "via": .string(via),
                "status": .string(e == .notFound ? "not_found" : "error"),
            ])
        } catch {
            phase = .failed(.network(error.localizedDescription))
        }
    }

    // MARK: Preview

    private func preview(_ p: ChallengeInvitePreview, terminal: Phase.Terminal?) -> some View {
        let c = p.challenge
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(c.name)
                    .brandDisplayFont()
                    .foregroundStyle(Brand.Color.textPrimary)
                Text("@\(c.creatorHandle) invited you")
                    .font(Brand.Font.body)
                    .foregroundStyle(Brand.Color.textSecondary)
                detailRow("WINDOW", ChallengeCopy.windowLine(startsAt: c.startsAt, endsAt: c.endsAt))
                detailRow("LENGTH", ChallengeCopy.durationLabel(c.durationPreset))
                detailRow(c.status == .upcoming ? "STARTS" : "TIME LEFT",
                          c.status == .upcoming
                            ? ChallengeCopy.relativeMoment(c.startsAt, now: model.now())
                            : ChallengeTiming.timeRemainingCopy(until: c.endsAt, now: model.now()).capitalized)
                detailRow("WHO'S IN", p.participants.isEmpty
                          ? "Nobody yet"
                          : "\(p.participants.map { "@\($0)" }.joined(separator: ", ")) (\(p.participants.count) of \(c.maxParticipants))")
            }
            .padding(18)
            .glassEffect(ChallengeStyle.glass, in: .rect(cornerRadius: Brand.Radius.card))

            if terminal == nil {
                Text(ChallengeCopy.ruleCard(startsAt: c.startsAt, endsAt: c.endsAt))
                    .font(Brand.Font.body)
                    .foregroundStyle(Brand.Color.textSecondary)
                    .padding(16)
                    .background(Brand.Color.bgElevated.opacity(0.75), in: .rect(cornerRadius: Brand.Radius.card))
            }

            if p.needsHandle && !claimedInline && terminal == nil {
                handleClaim
            }

            if let joinError {
                Label(ChallengeCopy.message(for: joinError), systemImage: "exclamationmark.circle.fill")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.alertCaution)
            }

            action(for: p, terminal: terminal)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Brand.Font.mono(size: 9, weight: .semibold, relativeTo: .caption2))
                .tracking(1.1)
                .foregroundStyle(Brand.Color.textTertiary)
            Text(value)
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func action(for p: ChallengeInvitePreview, terminal: Phase.Terminal?) -> some View {
        switch terminal {
        case .alreadyIn:
            VStack(spacing: 10) {
                Text("You're already in this one.")
                    .font(Brand.Font.body)
                    .foregroundStyle(Brand.Color.textSecondary)
                Button {
                    if let d = model.details[p.challenge.id] {
                        dismiss(); onJoined(d)
                    } else {
                        Task {
                            await model.loadDetail(id: p.challenge.id)
                            if let d = model.details[p.challenge.id] { dismiss(); onJoined(d) }
                        }
                    }
                } label: { primaryLabel("Open", enabled: true) }
                .buttonStyle(.plain)
            }
        case .full:
            terminalNotice("This one's full", "10 of 10 spotters are in. Ask @\(p.challenge.creatorHandle) to start another.")
        case .ended:
            terminalNotice("This one's over", "It finished \(ChallengeCopy.relativeMoment(p.challenge.endsAt, now: model.now())). Start your own and send them the link.")
        case .cancelled:
            terminalNotice("This one was cancelled", "@\(p.challenge.creatorHandle) called it off before it started.")
        case nil:
            let blocked = p.needsHandle && !claimedInline
            Button { Task { await join(p) } } label: {
                HStack {
                    Spacer()
                    if isJoining {
                        ProgressView().scaleEffect(0.85).tint(Brand.Color.bgPrimary)
                    } else {
                        Text("Join")
                            .font(Brand.Font.mono(size: 15, weight: .bold, relativeTo: .subheadline))
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
                .background(blocked || isJoining ? Brand.Color.bgElevated : Brand.Color.cyan,
                            in: .rect(cornerRadius: Brand.Radius.row))
                .foregroundStyle(blocked || isJoining ? Brand.Color.textTertiary : Brand.Color.bgPrimary)
                .frame(minHeight: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(blocked || isJoining)
        }
    }

    private func terminalNotice(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Brand.Font.cardTitle)
                .foregroundStyle(Brand.Color.textPrimary)
            Text(body)
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Brand.Color.bgElevated.opacity(0.75), in: .rect(cornerRadius: Brand.Radius.card))
    }

    private func failed(_ e: ChallengesError) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(e == .notFound ? "No challenge with that code" : "Couldn't look that up")
                .font(Brand.Font.cardTitle)
                .foregroundStyle(Brand.Color.textPrimary)
            Text(ChallengeCopy.message(for: e))
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)
            Button {
                phase = .entry
            } label: { primaryLabel(e == .notFound ? "Try another code" : "Try again", enabled: true) }
            .buttonStyle(.plain)
        }
        .padding(18)
        .glassEffect(ChallengeStyle.glass, in: .rect(cornerRadius: Brand.Radius.card))
    }

    private func primaryLabel(_ title: String, enabled: Bool) -> some View {
        Text(title)
            .font(Brand.Font.mono(size: 15, weight: .bold, relativeTo: .subheadline))
            .foregroundStyle(enabled ? Brand.Color.bgPrimary : Brand.Color.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 46)
            .background(enabled ? Brand.Color.cyan : Brand.Color.bgElevated, in: .rect(cornerRadius: Brand.Radius.row))
            .contentShape(Rectangle())
    }

    // MARK: Inline handle claim

    private var handleClaim: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick a handle first")
                .font(Brand.Font.cardTitle)
                .foregroundStyle(Brand.Color.textPrimary)
            Text("It's what the other spotters see. Letters, numbers and underscores, 3 to 20 characters.")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textSecondary)
            HStack(spacing: 6) {
                Text("@").foregroundStyle(Brand.Color.textTertiary)
                TextField("handle", text: $handleDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Brand.Font.mono(size: 17, relativeTo: .body))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .accessibilityLabel("Handle")
                    .onChange(of: handleDraft) { _, _ in handleError = nil }
                    .onSubmit { Task { await claimHandle() } }
                if isClaiming { ProgressView().scaleEffect(0.75).tint(Brand.Color.cyan) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Brand.Color.bgPrimary.opacity(0.6), in: .rect(cornerRadius: Brand.Radius.row))
            if let handleError {
                Label(handleError, systemImage: "exclamationmark.circle.fill")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.alertCaution)
            }
            Button { Task { await claimHandle() } } label: {
                Text("Claim handle")
                    .font(Brand.Font.mono(size: 13, weight: .bold, relativeTo: .footnote))
                    .foregroundStyle(handleDraftValid ? Brand.Color.cyan : Brand.Color.textTertiary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!handleDraftValid || isClaiming)
        }
        .padding(16)
        .background(Brand.Color.bgElevated.opacity(0.75), in: .rect(cornerRadius: Brand.Radius.card))
    }

    private var handleDraftValid: Bool {
        let t = handleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 3 && t.count <= 20 && t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Mirrors SettingsScreen.saveHandle: register, claim, persist, identify.
    private func claimHandle() async {
        let trimmed = handleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard handleDraftValid else { return }
        isClaiming = true
        defer { isClaiming = false }
        do {
            let deviceId = try await accountClient.ensureRegistered()
            try await accountClient.claimHandle(trimmed)
            handle = trimmed
            UserDefaults.standard.set(trimmed, forKey: SpotterHandle.confirmedKey)
            Analytics.identify(deviceId, handle: trimmed)
            Analytics.capture("handle_claimed", ["result": .string("success"), "source": .string("challenge_join")])
            claimedInline = true
            handleError = nil
        } catch AccountError.handleTaken {
            handleError = "@\(trimmed) is already taken"
            Analytics.capture("handle_claimed", ["result": .string("taken"), "source": .string("challenge_join")])
        } catch AccountError.handleNotAllowed {
            handleError = "@\(trimmed) isn't allowed"
            Analytics.capture("handle_claimed", ["result": .string("not_allowed"), "source": .string("challenge_join")])
        } catch {
            Log.ui.error("Join sheet: handle claim failed: \(error, privacy: .public)")
            handleError = "Couldn't claim that right now. Check your connection."
        }
    }

    // MARK: Join

    private func join(_ p: ChallengeInvitePreview) async {
        guard let code = InviteCode.normalize(codeDraft) ?? p.challenge.code else { return }
        isJoining = true
        defer { isJoining = false }
        joinError = nil
        do {
            let detail = try await model.join(code: code)
            let total = p.challenge.endsAt.timeIntervalSince(p.challenge.startsAt)
            let elapsed = max(0, min(1, model.now().timeIntervalSince(p.challenge.startsAt) / max(total, 1)))
            Analytics.capture("challenge_joined", [
                "challenge_id": .string(detail.challenge.id),
                "participants_after": .int(detail.challenge.participantCount),
                "elapsed_fraction": .double(elapsed),
                "needed_handle": .bool(p.needsHandle),
                "new_user": .bool(detail.newDevice ?? false),
            ])
            dismiss()
            onJoined(detail)
        } catch let e as ChallengesError {
            joinError = e
        } catch {
            joinError = .network(error.localizedDescription)
        }
    }
}
