//
//  CountCopy.swift
//  Tailspot
//
//  Small English count formatter shared by compact UI labels and their
//  accessibility equivalents so singular copy cannot drift between surfaces.
//

import Foundation

nonisolated enum CountCopy {
    static func phrase(
        _ count: Int,
        singular: String,
        plural: String? = nil
    ) -> String {
        let noun = count == 1 ? singular : (plural ?? singular + "s")
        return "\(count.formatted()) \(noun)"
    }
}
