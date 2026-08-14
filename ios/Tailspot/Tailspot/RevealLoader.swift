//
//  RevealLoader.swift
//  Tailspot
//
//  The catch pipeline's channel into an ALREADY-PRESENTED reveal (capture-
//  lag work, 2026-08-13). The reveal historically presented only after the
//  whole pipeline finished (shutter → detector → compose → save), which left
//  ~1.4 s of dead air after the capture tap. Now the single-target path
//  presents the reveal immediately as a loading shell — flaps tumbling over
//  tap-time feed data, `SkyPlaceholder` holding the photo slot — and the
//  pipeline swaps the finished results in through this object as they land.
//
//  Design notes:
//  - `CardPlane` stays an immutable value snapshot (the reveal's "stable
//    even if SwiftData churns" rule is untouched); progress is modeled as
//    the loader REPLACING the snapshot, never as the view reading live rows.
//  - `@Observable` (not ObservableObject): CatchRevealView reads
//    `loader?.plane` inside its body, so mutations invalidate the view with
//    no @Published/objectWillChange plumbing. First use of Observation in
//    the app — the sensor managers predate it and stay ObservableObject.
//  - Implicitly @MainActor (project default isolation): the pipeline task
//    that mutates it and the view that reads it are both MainActor.
//
import Observation

@Observable
final class RevealLoader {
    /// The presentation snapshot. Starts as the tap-time shell (feed
    /// callsign/typecode → rarity/points; no photo, feed-only route) and is
    /// replaced wholesale with the row-built snapshot when the pipeline
    /// finishes. Swapping the whole value keeps every derived field (photo,
    /// focus, healed route, first-of-type) consistent in one update.
    var plane: CardPlane

    /// The persisted row, set once the pipeline saves it. The reveal's
    /// guess-round resolution freezes its answer onto this row (the shell
    /// presents before the row exists, so `PendingReveal.row` can't carry it).
    var row: Catch?

    /// The in-card bonus-round question, set at pipeline end when the
    /// scheduler fires one. Typically lands before the reveal settles (the
    /// round pops only post-settle, so nothing changes visually); if it lands
    /// after, CatchRevealView's `onChange` pops the chips late.
    var guess: GuessRoundQuestion?

    init(plane: CardPlane) {
        self.plane = plane
    }
}
