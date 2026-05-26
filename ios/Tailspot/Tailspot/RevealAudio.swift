//
//  RevealAudio.swift
//  Tailspot
//
//  Tiny wrapper around AudioServicesPlaySystemSoundID for the
//  multi-catch reveal's ascending chime. Uses iOS system sounds —
//  no bundled AIFF assets, no AVAudioEngine setup. Spec § 3.3,
//  follow-up § 11.1.
//

import AudioToolbox
import UIKit

enum RevealAudio {
    /// System sound IDs picked by ear for an ascending feel. Adjust
    /// freely — these are not pinned by tests. iPhone sound IDs are
    /// documented at https://github.com/TUNER88/iOSSystemSoundsLibrary.
    /// 1057 (Tink) → 1103 (BeginRecording) → 1054 (Anticipate)
    /// → 1304 (Headset In) → 1407 (Photo Shutter).
    private static let chimeLadder: [SystemSoundID] = [
        1057, 1103, 1054, 1304, 1407
    ]

    /// Plays the chime at the given step (0-based). Clamps to the
    /// last rung if `step` exceeds the ladder length.
    static func playChime(step: Int) {
        let safeStep = min(max(0, step), chimeLadder.count - 1)
        AudioServicesPlaySystemSound(chimeLadder[safeStep])
    }

    /// Convenience: play a medium haptic tap simultaneously with the
    /// chime — used by MultiCatchReveal's card landing.
    @MainActor
    static func tap(step: Int, intensity: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        playChime(step: step)
        let gen = UIImpactFeedbackGenerator(style: intensity)
        gen.prepare()
        gen.impactOccurred()
    }
}
