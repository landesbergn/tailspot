//
//  CatchPhotoFocusRecoveryTests.swift
//  TailspotTests
//
//  Pins the cyan-bracket → focus recovery, especially the pixel-buffer
//  ORIENTATION (top-left origin) — a flip here would center every backfilled
//  catch on the vertically-mirrored point. Synthetic images with a bracket
//  painted at a known normalized spot; the recovered focus must match.
//

import CoreGraphics
import Testing
import UIKit
@testable import Tailspot

@Suite("CatchPhotoFocusRecovery")
struct CatchPhotoFocusRecoveryTests {

    /// A sky JPEG with a brand-cyan block centered at `focus` (top-left
    /// normalized). `block` is the block's side as a fraction of the width.
    private func skyJPEG(cyanAt focus: CGPoint, block: CGFloat = 0.14,
                         size: CGSize = CGSize(width: 1080, height: 1920)) -> Data {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor(red: 0.42, green: 0.60, blue: 0.86, alpha: 1).setFill()   // sky
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0, green: 212 / 255, blue: 1, alpha: 1).setFill()    // 0x00D4FF
            let side = block * size.width
            ctx.fill(CGRect(x: focus.x * size.width - side / 2,
                            y: focus.y * size.height - side / 2,
                            width: side, height: side))
        }
        return img.jpegData(compressionQuality: 0.9)!
    }

    @Test func recoversFocusAtKnownPoint() {
        // Upper-right: the RPA4343-style plane sits high and off-center.
        let f = CatchPhotoFocusRecovery.recoverFocus(
            fromJPEG: skyJPEG(cyanAt: CGPoint(x: 0.70, y: 0.25)))
        #expect(f != nil)
        #expect(abs((f?.x ?? 0) - 0.70) < 0.04)
        #expect(abs((f?.y ?? 0) - 0.25) < 0.04)
    }

    @Test func topAndBottomAreNotFlipped() {
        // The load-bearing orientation check: a block near the TOP must
        // recover a small y, near the BOTTOM a large y.
        let top = CatchPhotoFocusRecovery.recoverFocus(
            fromJPEG: skyJPEG(cyanAt: CGPoint(x: 0.5, y: 0.12)))
        let bottom = CatchPhotoFocusRecovery.recoverFocus(
            fromJPEG: skyJPEG(cyanAt: CGPoint(x: 0.5, y: 0.88)))
        #expect((top?.y ?? 1) < 0.25)
        #expect((bottom?.y ?? 0) > 0.75)
    }

    @Test func plainSkyReturnsNil() {
        // No bracket → leave the crop centered (nil), don't invent a focus.
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        let plain = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 700), format: fmt)
            .image { ctx in
                UIColor(red: 0.42, green: 0.60, blue: 0.86, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 700))
            }.jpegData(compressionQuality: 0.9)!
        #expect(CatchPhotoFocusRecovery.recoverFocus(fromJPEG: plain) == nil)
    }

    @Test func invalidDataReturnsNil() {
        #expect(CatchPhotoFocusRecovery.recoverFocus(fromJPEG: Data([0, 1, 2, 3])) == nil)
    }
}
