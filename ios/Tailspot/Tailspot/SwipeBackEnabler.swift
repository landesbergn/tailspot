//
//  SwipeBackEnabler.swift
//  Tailspot
//
//  Restores the interactive swipe-from-left-edge "pop" gesture on screens
//  that hide the system navigation bar.
//
//  The Hangar's child screens (SetDetailScreen, ModelDetailScreen,
//  CatchDetailView) render their own back chrome (HangarChildBar) and hide the
//  system bar with `.toolbar(.hidden, for: .navigationBar)`. UIKit disables the
//  `interactivePopGestureRecognizer` whenever the nav bar is hidden — so the
//  edge swipe stops working. This reattaches the gesture (gated to a stack
//  depth > 1, so there's no root-level freeze).
//
//  Usage: `.swipeBackEnabled()` on any view that hides the nav bar.
//

import SwiftUI
import UIKit

private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Proxy { Proxy() }
    func updateUIViewController(_ proxy: Proxy, context: Context) { proxy.reenable() }

    /// A zero-size child view controller living in the SwiftUI hierarchy. It
    /// can reach the enclosing UINavigationController (NavigationStack is backed
    /// by one) and re-enable its pop gesture.
    final class Proxy: UIViewController, UIGestureRecognizerDelegate {
        func reenable() {
            guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
            gesture.isEnabled = true
            gesture.delegate = self
        }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            reenable()
        }
        // Re-assert on every appearance — including when a deeper screen is
        // popped and this one returns to the top of the stack.
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            reenable()
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}

extension View {
    /// Re-enables edge-swipe-to-go-back on a screen that hides the nav bar.
    func swipeBackEnabled() -> some View {
        background(SwipeBackEnabler())
    }
}
