//
//  HangarZoomNamespace.swift
//  Tailspot
//
//  Shared `Namespace` plumbing for the Hangar drill-down zoom
//  transitions (iOS 18+ `.navigationTransition(.zoom)`).
//
//  Why an Environment value: the zoom transition matches a SOURCE
//  (`.matchedTransitionSource(id:in:)` on a tapped cell) with a
//  DESTINATION (`.navigationTransition(.zoom(sourceID:in:))` on the
//  pushed screen) by a shared `Namespace.ID`. In our Hangar the source
//  cell lives in one view (e.g. `SetDetailView`'s model row) while the
//  destination is built by a *different* view — `HangarView`'s
//  `.navigationDestination(for:)` closure. A `@Namespace` declared in
//  either one can't reach the other directly, and the route value that
//  bridges them is a plain `Hashable` (no place to stash a namespace).
//
//  So `HangarView` owns ONE `@Namespace` at the NavigationStack root and
//  publishes it through the environment. Every source cell and every
//  destination reads the same namespace from here, and SwiftUI can match
//  them across the push. One namespace for the whole stack is fine — the
//  per-transition identity comes from the `id:` (the route's stable key),
//  not from separate namespaces.
//

import SwiftUI

extension EnvironmentValues {
    /// The Hangar NavigationStack's shared zoom-transition namespace.
    /// `nil` outside a Hangar stack (e.g. SwiftUI previews of a child
    /// view in isolation), in which case callers skip the zoom modifiers
    /// and fall back to a standard push — see `matchedZoomSource` /
    /// `zoomTransition` below.
    @Entry var hangarZoomNamespace: Namespace.ID? = nil
}

extension View {
    /// Marks this view as the zoom SOURCE for `id`, but only when a
    /// Hangar namespace is present. Apply to a `NavigationLink`'s label
    /// (the tapped cell). The matching destination calls
    /// `zoomTransition(id:)` with the same `id`.
    @ViewBuilder
    func matchedZoomSource(id: some Hashable, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Declares this pushed screen as the zoom DESTINATION for `id`.
    /// No-ops (standard push) when no Hangar namespace is in scope.
    @ViewBuilder
    func zoomTransition(id: some Hashable, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}
