//
//  CatchPhotoReplayMask.swift
//  Tailspot
//
//  The ONE way catch-photo views opt into PostHog session-replay masking.
//  Every user-photo render site (`RevealPhoto`, `CatchCardView`'s photo,
//  `FocusThumbnail`) routes through `.catchPhotoReplayMask()` instead of
//  calling `.postHogMask()` directly, so the share/export path can turn
//  the mask OFF structurally.
//
//  Why the mask must be REMOVED (not just disabled) for ImageRenderer:
//  `.postHogMask()` injects hidden UIKit platform views around the SwiftUI
//  view to tag it for replay redaction — including, on iOS 26+, a
//  FULL-SIZED UIViewRepresentable overlay (posthog-ios's frame-capture
//  view for layer-backed SwiftUI). ImageRenderer cannot render platform
//  views and draws each one as the yellow no-entry placeholder — which is
//  exactly the "photo mask" that was covering the hero on shared catch
//  cards (field report 2026-08-12; the marketing round hit the same thing,
//  CHANGELOG 2026-07-21). And `postHogMask(false)` does NOT help: the
//  SDK's modifier still injects the tag views and only flips their
//  redaction flag, so the placeholder appears either way. The only safe
//  off-switch is to not apply the modifier at all.
//
//  The environment flag scopes that off-switch to offscreen render trees
//  (`CatchShare.image`): those pixels never appear on screen, so session
//  replay can never capture them — replay privacy is unchanged. Every
//  on-screen tree keeps the default (`false`) and stays masked.
//

import SwiftUI
import PostHog

extension EnvironmentValues {
    /// True only inside offscreen ImageRenderer trees (the share-card
    /// render). Never set this on a view that appears on screen — the
    /// mask is the GA privacy posture for user catch photos in session
    /// replay (see PostHogSessionReplay.swift).
    @Entry var replayMaskingDisabled: Bool = false
}

extension View {
    /// Masks this view from PostHog session replay when it shows a USER
    /// catch photo (`isUserPhoto`, default true) — unless the surrounding
    /// tree disabled masking via `\.replayMaskingDisabled` (offscreen
    /// share renders). Pass false for public imagery (Planespotters
    /// heroes), which never needs the mask.
    func catchPhotoReplayMask(_ isUserPhoto: Bool = true) -> some View {
        modifier(CatchPhotoReplayMask(isUserPhoto: isUserPhoto))
    }
}

private struct CatchPhotoReplayMask: ViewModifier {
    let isUserPhoto: Bool
    @Environment(\.replayMaskingDisabled) private var replayMaskingDisabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if isUserPhoto && !replayMaskingDisabled {
            content.postHogMask()
        } else {
            // Structurally unmodified — no PostHog tag views injected.
            // (The branch changes view identity, but the flag is constant
            // per tree: always false on screen, always true in a share
            // render — so no live view ever flips between branches.)
            content
        }
    }
}
