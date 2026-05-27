//
//  HangarGlyph.swift
//  Tailspot
//
//  The hangar icon used wherever we need to evoke the collection
//  ("Hangar") surface — currently the bottom hangar button in
//  ContentView and the inline lockup in HangarView's custom top bar.
//
//  Now wraps the SF Symbol `airplane.path.dotted` — a plane with a
//  dashed trail. Apple's design reads cleaner at small sizes than
//  the hand-drawn pentagon we shipped before, and the trailing path
//  has a "this plane went somewhere and was collected" connotation
//  that fits the Hangar metaphor better than a literal building.
//
//  API kept stable: callers still pass `tint` and `lineWidth`. The
//  `lineWidth` parameter is preserved for source compatibility but
//  is now unused (SF Symbols control stroke weight via the symbol
//  configuration, not a per-call lineWidth).
//

import SwiftUI

struct HangarGlyph: View {
    /// Retained for source compatibility with the prior hand-drawn
    /// version. Ignored: SF Symbols use weight/scale to control
    /// stroke thickness, not a free-form lineWidth.
    var lineWidth: CGFloat = 2
    var tint: Color = .primary

    var body: some View {
        Image(systemName: "airplane.path.dotted")
            .resizable()
            .scaledToFit()
            .foregroundStyle(tint)
    }
}

#Preview {
    HStack(spacing: 24) {
        HangarGlyph(tint: .cyan)
            .frame(width: 24, height: 24)
        HangarGlyph(tint: .cyan)
            .frame(width: 44, height: 44)
        HangarGlyph(tint: .white)
            .frame(width: 22, height: 22)
    }
    .padding(40)
    .background(Color.black)
}
