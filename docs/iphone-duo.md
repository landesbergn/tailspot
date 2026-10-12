# iPhone Duo readiness

iPhone Duo is Apple's first foldable (announced 2026-09-09, ships **2026-10-23**,
iOS 27, A20 Pro). Book-style fold; both displays are taller than wide:
inner 7.6" (1878 × 2670 px, ≈ 0.70 w/h), outer 5.4" (1398 × 2034 px, ≈ 0.69).
Rear main camera is 26 mm-equivalent, the same as the iPhone 16 1× that our
FOV numbers were tuned on. Sources: Apple's *Prepare your app for iPhone Duo*
tech talk and the iPhone Duo group-lab Q&A on the developer forums
(thread 847644).

## What changes for Tailspot

| Area | Apple's guidance | Tailspot status |
|---|---|---|
| Portrait pin | Outer display honors `UISupportedInterfaceOrientations`; the **inner display does not** | **Guarded.** `SidewaysHoldGuard` covers the AR view with a "hold it upright" card whenever the layout is wider than tall, so a rotated UI can't produce a 90°-off ID. Fires `sideways_hold_guard_shown`. Inert on slab iPhones. |
| Field of view | n/a (our own model) | **Fixed.** Both Duo displays are wider than the 9:16 video, so aspect-fill crops top/bottom instead of the sides. `CameraFOV` re-crops the iPhone 16 calibration per screen shape: Duo ≈ 66° × 60° vs 56° × 72°. Slab iPhones unchanged (unit-tested). |
| Size classes | Inner display reports regular × regular | Nothing to do: the app never branches on size class. |
| `UIScreen.main` | Ambiguous with two displays; use the window scene's screen | Not used anywhere. |
| Core Motion | Attitude is in the **chassis** frame unless `CMMotionManager.deviceMotionBody` is set to the view's display (iOS 27.1 SDK) | **Open — needs Xcode 27.1 + a device.** Our elevation (`asin(gravity.z)`) and roll are chassis-frame. Fine closed and fully open (both halves coplanar); a *partially* open hinge may skew elevation if the IMU and camera sit in different halves. |
| Hinge | `onHingeChange` / `UIHingeInteraction` (iOS 27.1) give status + angle | **Open — 27.1.** Candidate: treat "partially open" like the sideways guard (block spotting) until field data says it's safe. |
| Camera | Rear camera unchanged; `AVCaptureDeviceDirectionCoordinator` matters for front/selfie flips | No change needed: we only use `.back` `.builtInWideAngleCamera`. |
| Letterboxing | iOS 26 SDK: iPhone aspect on inner. iOS 27 SDK: extends left of the status bar. **iOS 27.1 SDK: edge to edge** | The build SDK is whatever Xcode Cloud's workflow selects (App Store Connect, not this repo). Local Xcode is 27.0 and GitHub CI pins 26.6. Moving to 27.1 is a release-train decision. |
| Screenshots | Duo sets (inner 2007 × 2853, outer 1398 × 2034) optional now; reportedly **required from April 2027** for apps built with the 27.1 SDK | Not made yet. The 6.9" set stays the required fallback. |

## Before calling it done (needs Noah / hardware)

1. **Field test on a real iPhone Duo** (or a Duo workshop): closed, fully open,
   and half-open. Check the reticle lands on a plane at screen center *and*
   near the edges (that's where the FOV change shows), and that turning the
   open phone sideways shows the hold-upright card.
2. **Xcode 27.1:** adopt `deviceMotionBody` behind `if #available(iOS 27.1, *)`
   (body = the AR view), add hinge handling, then test in Device Hub's
   iPhone Duo poses.
3. **Confirm the Xcode Cloud workflow's Xcode version** in App Store Connect
   before the next train, since it decides letterboxing on the inner display.
4. **Duo screenshots** for the inner display before the April 2027 cutoff.
