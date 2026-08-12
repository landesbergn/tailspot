//
//  ShareCardMaskRegressionTests.swift
//  TailspotTests
//
//  Regression net for the "photo mask on shared catch cards" bug
//  (field report 2026-08-12): `.postHogMask()` injects hidden UIKit tag
//  views around the catch photo, and ImageRenderer draws platform views
//  as a yellow no-entry placeholder — so every shared card covered its
//  hero with the placeholder instead of the photo. The fix routes photo
//  masking through `catchPhotoReplayMask` and disables it (structurally —
//  the modifier is not applied at all) inside `CatchShare.uiImage`'s
//  offscreen render tree via `\.replayMaskingDisabled`.
//
//  Unlike ShareCardSnapshotTests (a visual-pass harness, no assertions —
//  which is why this regressed silently), this test ASSERTS on pixels:
//  it renders the production share path with a solid-magenta catch photo
//  and requires a large magenta region in the output. With the mask
//  present, the placeholder covers the hero and the count drops to ~0.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("Share card mask regression")
struct ShareCardMaskRegressionTests {

    /// Saturated magenta — nowhere in the card chrome (cyan/gold/dark
    /// palette), so any matching pixel in the render came from the photo.
    /// JPEG round-trips a solid color nearly exactly; the match tolerance
    /// below absorbs the residual compression drift.
    private func makeSolidMagentaPhoto() -> URL? {
        let size = CGSize(width: 1200, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(red: 1, green: 0, blue: 1, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        guard let data = img.jpegData(compressionQuality: 0.9) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("share_mask_regression_photo.jpg")
        do {
            try data.write(to: url)
        } catch {
            return nil
        }
        return url
    }

    /// Count pixels within tolerance of the magenta marker.
    private func magentaPixelCount(in image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return 0 }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        // The raw pointer handed to CGContext must stay valid through the
        // draw + scan, so everything runs inside withUnsafeMutableBytes.
        return data.withUnsafeMutableBytes { buf -> Int in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return 0 }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            let px = buf.bindMemory(to: UInt8.self)
            var count = 0
            var i = 0
            while i < px.count {
                let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
                if r > 200, g < 80, b > 200 { count += 1 }
                i += 4
            }
            return count
        }
    }

    @Test("CatchShare.uiImage renders the local catch photo, not a mask placeholder")
    func shareRenderContainsPhotoPixels() throws {
        let photoURL = try #require(makeSolidMagentaPhoto())
        defer { try? FileManager.default.removeItem(at: photoURL) }

        let plane = CardPlane(
            callsign: "KAL082", model: "Airbus A380-800",
            carrier: "Korean Air",
            rarity: .rare, type: .wide,
            altText: "1,675 ft", speedText: "179 kt", distText: "1.2 km",
            photoURL: photoURL, photoFocus: nil,
            isFirstOfType: true)

        let ui = try #require(CatchShare.uiImage(for: plane))
        let magenta = magentaPixelCount(in: ui)

        // The hero slot is ~960×540 px at the share render's 3× scale, so a
        // photo that actually renders contributes hundreds of thousands of
        // matching pixels; a placeholder-covered (or missing) hero yields ~0.
        #expect(magenta > 50_000,
                "Shared card lost its catch photo (found \(magenta) photo pixels). If the hero shows a yellow no-entry placeholder, a PostHog mask tag view is back inside the ImageRenderer tree — see CatchPhotoReplayMask.swift.")
    }
}
#endif
