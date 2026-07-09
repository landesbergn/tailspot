//
//  GuessRoundView.swift
//  Tailspot
//
//  The pre-reveal BONUS ROUND (game-layer PR3, plan 2026-07-09-001 §2 A1 / §3).
//  When the scheduler fires on a fresh single catch, this screen slides in
//  BEFORE the reveal: the reveal surface with the answer MASKED. You see the
//  captured photo hero, a question ("Where's it headed?" / "CALL THE TYPE"),
//  and 4 option chips — then guess blind. The reveal that follows shows the
//  truth AND, on a correct call, the bonus in its ledger.
//
//  Shape (locked design + decisions D1/D5):
//    - one shared interstitial, question kind (route/type) varies;
//    - UNTIMED — pacing protection comes from cadence (GuessScheduler), not a
//      stress timer, so there's no countdown;
//    - a correct tap gets a brief positive beat, a wrong tap a red MISS FLASH
//      that also reveals which chip was right; either way we hand to the reveal
//      (a wrong guess shows NO rub-it-in line there — the flash was the answer);
//    - a quiet SKIP → straight to the reveal, no penalty.
//
//  Purely presentational: it renders whatever `GuessRoundQuestion` the caller
//  built from `GuessOptions` and reports the outcome through `onComplete`. No
//  analytics, no persistence, no SwiftData here — ContentView owns the seam
//  (freeze-on-answer + telemetry + the guess→reveal handoff), which keeps this
//  view snapshot-testable off-device.
//
//  Visual language: photo hero + `RP` palette borrowed from CatchRevealView so
//  the guess and the reveal read as one surface; chips match OnboardingFlow's
//  bgElevated + cyan-hairline styling; prompt in the AR view's cyan mono.
//

import SwiftUI

// MARK: - GuessRoundQuestion

/// The question a `GuessRoundView` renders — a route or a type question.
/// Built by the caller (ContentView) from `GuessOptions`, so the view stays a
/// pure renderer of a prompt + 4 chips + a completion callback. `nonisolated`
/// per repo convention (pure value data wrapping Sendable option sets).
nonisolated enum GuessRoundQuestion: Equatable, Sendable {
    case route(GuessOptions.RouteQuestion)
    case type(GuessOptions.TypeQuestion)

    /// The wire/stored kind — mirrors `GuessKind` for the freeze + telemetry.
    var kind: GuessKind {
        switch self {
        case .route: return .route
        case .type:  return .type
        }
    }

    /// The 4 shuffled option chips (correct answer embedded).
    var options: [GuessOptions.Option] {
        switch self {
        case .route(let q): return q.options
        case .type(let q):  return q.options
        }
    }

    /// The correct option's `value` — the local verdict compares a tap's
    /// `value` against this (`tapped.value == correctValue`).
    var correctValue: String {
        switch self {
        case .route(let q): return q.correctValue
        case .type(let q):  return q.correctValue
        }
    }

    /// The prompt copy. Route keys off the asked endpoint (the one farther
    /// from the observer); type is a fixed callout (plan §A1/§B).
    var prompt: String {
        switch self {
        case .route(let q):
            switch q.endpoint {
            case .origin:      return "Where's it coming from?"
            case .destination: return "Where's it headed?"
            }
        case .type:
            return "CALL THE TYPE"
        }
    }
}

// MARK: - GuessRoundView

struct GuessRoundView: View {
    let question: GuessRoundQuestion
    /// Hero photo — the same captured JPEG the reveal shows (file URL), or nil
    /// for the sky placeholder. Reuses `RevealPhoto` so guess and reveal match.
    let photoURL: URL?
    /// Where the plane sits in the photo (`Catch.photoFocus`) — anchors the
    /// hero's aspect-fill crop on the plane, same as the reveal.
    let photoFocus: CGPoint?
    /// Called exactly once when the round resolves: a tapped answer
    /// (`answeredValue` = the option's wire value, `correct` = local verdict)
    /// or SKIP (`answeredValue == nil`, `correct == false`).
    let onComplete: (_ answeredValue: String?, _ correct: Bool) -> Void

    /// The tapped option's value, or nil until a tap. Drives the chip flash.
    @State private var chosen: String?
    /// Latches on the first tap / skip so the round resolves exactly once and
    /// further taps are ignored while the beat plays out.
    @State private var resolved = false
    /// Sensory-feedback triggers — counters so repeats can't collapse.
    @State private var successBeat = 0
    @State private var missBeat = 0

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width - 28, 420)
            ZStack {
                RP.bg.ignoresSafeArea()
                content(width: width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A correct tap gets a success beat; a wrong tap an error buzz.
            .sensoryFeedback(.success, trigger: successBeat)
            .sensoryFeedback(.error, trigger: missBeat)
        }
    }

    // The full guess layout, parameterized by the card width so it scales the
    // same way the reveal does (metrics tuned for a 300pt-wide surface).
    private func content(width: CGFloat) -> some View {
        let scale = width / 300
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            hero(scale: scale)
            promptBlock(scale: scale)
                .padding(.top, 22 * scale)
            chips(scale: scale)
                .padding(.top, 20 * scale)
            Spacer(minLength: 0)
            skipButton(scale: scale)
                .padding(.bottom, 28)
        }
        .frame(width: width)
    }

    // MARK: Hero

    private func hero(scale: CGFloat) -> some View {
        RevealPhoto(url: photoURL, focus: photoFocus)
            .frame(height: 200 * scale)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(RP.rule, lineWidth: 1)
            )
    }

    // MARK: Prompt

    private func promptBlock(scale: CGFloat) -> some View {
        VStack(spacing: 8 * scale) {
            Text("BONUS ROUND")
                .font(.system(size: 11 * scale, weight: .semibold, design: .monospaced))
                .tracking(3)
                .foregroundStyle(Brand.Color.cyan.opacity(0.7))
            Text(question.prompt)
                .font(.system(size: 20 * scale, weight: .bold, design: .monospaced))
                .foregroundStyle(Brand.Color.cyan)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
    }

    // MARK: Chips

    private func chips(scale: CGFloat) -> some View {
        VStack(spacing: 10 * scale) {
            // `Option` values are unique within a set (GuessOptions guarantees
            // 4 unique displays/values), so `value` is a safe identity.
            ForEach(question.options, id: \.value) { option in
                answerChip(option, scale: scale)
            }
        }
        .padding(.horizontal, 20)
    }

    private func answerChip(_ option: GuessOptions.Option, scale: CGFloat) -> some View {
        let state = chipState(for: option.value)
        return Button {
            tap(option)
        } label: {
            HStack(spacing: 8) {
                Text(option.display)
                    .font(.system(size: 15 * scale, weight: .semibold, design: .monospaced))
                    .foregroundStyle(state.textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                // Post-resolve marks: a check on the right answer, an X on a
                // wrong pick. Hidden pre-resolve (idle chips carry no glyph).
                switch state {
                case .correct:
                    Image(systemName: "checkmark")
                        .font(.system(size: 13 * scale, weight: .bold))
                        .foregroundStyle(Brand.Color.alertNormal)
                case .wrong:
                    Image(systemName: "xmark")
                        .font(.system(size: 13 * scale, weight: .bold))
                        .foregroundStyle(Brand.Color.alertWarning)
                case .idle, .dimmed:
                    EmptyView()
                }
            }
            .padding(.horizontal, 16 * scale)
            .padding(.vertical, 14 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(state.background, in: .rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(state.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(resolved)
        .animation(.easeOut(duration: 0.18), value: resolved)
    }

    // MARK: Skip

    private func skipButton(scale: CGFloat) -> some View {
        Button(action: skip) {
            Text("SKIP")
                .font(.system(size: 12 * scale, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(RP.faint)
                .padding(.vertical, 8)
                .padding(.horizontal, 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(resolved)
        // The SKIP option retires the instant the user commits to an answer.
        .opacity(resolved ? 0 : 1)
    }

    // MARK: - Chip state

    private enum ChipState {
        case idle       // pre-resolve: tappable
        case correct    // post-resolve: the right answer (green)
        case wrong      // post-resolve: the tapped wrong answer (red)
        case dimmed     // post-resolve: an untaken wrong answer

        var background: Color {
            switch self {
            case .idle:    return Brand.Color.bgElevated
            case .correct: return Brand.Color.alertNormal.opacity(0.15)
            case .wrong:   return Brand.Color.alertWarning.opacity(0.15)
            case .dimmed:  return Brand.Color.bgElevated.opacity(0.5)
            }
        }

        var border: Color {
            switch self {
            case .idle:    return Brand.Color.cyan.opacity(0.20)
            case .correct: return Brand.Color.alertNormal
            case .wrong:   return Brand.Color.alertWarning
            case .dimmed:  return Brand.Color.cyan.opacity(0.06)
            }
        }

        var textColor: Color {
            switch self {
            case .idle, .correct, .wrong: return Brand.Color.textPrimary
            case .dimmed:                 return Brand.Color.textTertiary
            }
        }
    }

    private func chipState(for value: String) -> ChipState {
        guard resolved else { return .idle }
        if value == question.correctValue { return .correct }
        if value == chosen { return .wrong }
        return .dimmed
    }

    // MARK: - Interaction

    private func tap(_ option: GuessOptions.Option) {
        guard !resolved else { return }
        chosen = option.value
        let correct = option.value == question.correctValue
        withAnimation(.easeOut(duration: 0.18)) { resolved = true }
        if correct { successBeat += 1 } else { missBeat += 1 }
        // A brief beat so the verdict registers on-screen (a wrong answer lingers
        // a touch longer so the user sees which chip was right), then hand off.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(correct ? 0.7 : 1.15))
            onComplete(option.value, correct)
        }
    }

    private func skip() {
        guard !resolved else { return }
        resolved = true
        onComplete(nil, false)
    }

    #if DEBUG
    /// Renders the guess screen at its initial (unanswered) state and a
    /// concrete size for the snapshot / visual-pass test
    /// (`GuessRoundSnapshotTests`), mirroring `CatchRevealView._snapshotScreen`.
    /// Concrete `.frame` (not the body's greedy `maxHeight: .infinity`) because
    /// ImageRenderer double-renders greedy frames. DEBUG-only.
    @MainActor func _snapshotScreen(width: CGFloat, size: CGSize) -> some View {
        content(width: width)
            .frame(width: size.width, height: size.height)
            .background(RP.bg)
    }
    #endif
}

// MARK: - GuessRoundPlanner

/// The pure translation from a catch batch + its single fresh row to the
/// `GuessScheduler` inputs — factored out of ContentView so the "should this
/// catch get a bonus round?" decision is unit-testable off the MainActor and
/// ContentView's sequencing stays a thin call. `nonisolated` per convention.
///
/// NOTE the round is offered ONLY for a fresh single catch (a duplicate awards
/// no points to bonus; a multi-catch owns its own `MultiCatchReveal`; a
/// suspect stacks a Keep/Discard question we don't game on top of). The
/// scheduler still owns cadence — this only derives its inputs.
nonisolated enum GuessRoundPlanner {

    /// The `GuessScheduler` inputs a catch batch produces.
    struct Inputs: Equatable, Sendable {
        /// Exactly one fresh row and no duplicates — the only shape eligible
        /// for a round (the batch gate).
        let isFreshSingle: Bool
        /// The row was gate-flagged (`Catch.suspectReason != nil`).
        let isSuspect: Bool
        /// A route question can be built from the row's frozen endpoints.
        let routeAvailable: Bool
        /// A type question can be built from the row's typecode.
        let typeAvailable: Bool

        /// A round can only fire when the batch is a fresh single AND at least
        /// one question kind can render honest options. (Cadence + the suspect
        /// guard are the scheduler's call, not this flag's.)
        var canOfferRound: Bool {
            isFreshSingle && (routeAvailable || typeAvailable)
        }
    }

    static func inputs(
        freshCount: Int,
        duplicateCount: Int,
        suspectReason: String?,
        originIcao: String?,
        destIcao: String?,
        typecode: String?
    ) -> Inputs {
        Inputs(
            isFreshSingle: freshCount == 1 && duplicateCount == 0,
            isSuspect: suspectReason != nil,
            routeAvailable: GuessOptions.routeAvailable(originIcao: originIcao, destIcao: destIcao),
            typeAvailable: GuessOptions.typeAvailable(typecode: typecode)
        )
    }
}
