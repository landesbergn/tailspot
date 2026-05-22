//
//  PublicScreens.swift
//  Tailspot
//
//  The "public surfaces" set from the design canvas:
//
//   - LeaderboardScreen — anonymous global. No backend yet, so this
//     ships with mocked rows and the user's row injected based on
//     their on-device totals. The mock row text says "preview" so
//     it's clear this isn't live data.
//
//   - ShareCardSheet — a shareable card composed in SwiftUI, handed
//     to `ShareLink` as an `Image`-renderable view.
//
//   - PublicHangarScreen — visit another spotter's profile (also
//     placeholder; routed via @AppStorage handle for now).
//

import SwiftUI
import SwiftData

// MARK: - Leaderboard (mocked)

struct LeaderboardScreen: View {
    enum Window: String, CaseIterable, Identifiable {
        case weekly = "Weekly"
        case monthly = "Monthly"
        case allTime = "All-time"
        var id: String { rawValue }
    }

    @Query private var catches: [Catch]
    @AppStorage(SpotterHandle.storageKey) private var handle: String = SpotterHandle.defaultPlaceholder
    @State private var window: Window = .weekly

    private var rows: [LeaderRow] {
        // Mock data — the canvas spec is anonymous-global-only.
        // We seed the table and inject the user's row at the
        // position implied by their total points.
        let me = LeaderRow(
            rank: nil,
            handle: handle,
            points: ProfileStats(catches: catches).totalPoints,
            countries: Set(catches.map(\.icao24)).count,
            isMe: true
        )
        var seed: [LeaderRow] = [
            .init(rank: 1, handle: "vapor_trail",    points: 38_420, countries: 287),
            .init(rank: 2, handle: "approach_287",   points: 31_605, countries: 244),
            .init(rank: 3, handle: "cabin_pressure", points: 28_910, countries: 219),
            .init(rank: 4, handle: "feet_dry",       points: 22_104, countries: 178),
            .init(rank: 5, handle: "heavy_metal",    points: 19_350, countries: 162),
            .init(rank: 6, handle: "contrail_cam",   points: 14_220, countries: 143),
            .init(rank: 7, handle: "tower_clearance",points: 11_840, countries: 121),
            .init(rank: 8, handle: "max_alt",        points:  9_640, countries: 110),
            .init(rank: 9, handle: "rwy_28r",        points:  7_315, countries:  98),
            .init(rank:10, handle: "blue_hour",      points:  5_902, countries:  84),
        ]
        // Slot the user in by points.
        seed.append(me)
        seed.sort { $0.points > $1.points }
        // Renumber ranks.
        for i in seed.indices { seed[i].rank = i + 1 }
        return seed
    }

    var body: some View {
        List {
            Section {
                podium
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                Picker("Window", selection: $window) {
                    ForEach(Window.allCases) { w in
                        Text(w.rawValue).tag(w)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(rows) { row in
                    NavigationLink(value: row.handle) {
                        leaderRow(row)
                    }
                    .listRowBackground(row.isMe
                                       ? Brand.Color.cyan.opacity(0.12)
                                       : Color.clear)
                }
            } footer: {
                Text("Anonymous global. Handles are visible; identities aren't tied to Apple ID. Preview data — live leaderboard ships with the backend.")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textTertiary)
            }

            // Coaching banner shown only when the user is below
            // top 10 — pulls them toward a concrete next milestone.
            if let climb = climbCTA {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CLIMB")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(Brand.Color.cyan)
                        Text(climb.headline)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Brand.Color.textPrimary)
                        Text(climb.detail)
                            .font(Brand.Font.caption)
                            .foregroundStyle(Brand.Color.textSecondary)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Leaderboard")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: String.self) { handle in
            PublicHangarScreen(handle: handle)
        }
    }

    /// "Climb 4 places to break top 10" — only renders when the
    /// user is currently outside the top 10. Computes how many
    /// points they need to overtake the row at rank 10.
    private var climbCTA: (headline: String, detail: String)? {
        let me = rows.first { $0.isMe }
        guard let me, let myRank = me.rank, myRank > 10 else { return nil }
        guard let target = rows.first(where: { $0.rank == 10 }) else { return nil }
        let placesToClimb = myRank - 10
        let pointsNeeded = max(0, target.points - me.points + 1)
        return (
            headline: "Climb \(placesToClimb) place\(placesToClimb == 1 ? "" : "s") to break top 10",
            detail: "Need ~\(pointsNeeded.formatted(.number)) more points this \(window.rawValue.lowercased()) period."
        )
    }

    // MARK: - Podium

    private var podium: some View {
        HStack(alignment: .bottom, spacing: 8) {
            podiumColumn(row: rows.first(where: { $0.rank == 2 }), height: 90, rank: 2)
            podiumColumn(row: rows.first(where: { $0.rank == 1 }), height: 130, rank: 1)
            podiumColumn(row: rows.first(where: { $0.rank == 3 }), height: 70, rank: 3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(Brand.Color.bgElevated)
    }

    private func podiumColumn(row: LeaderRow?, height: CGFloat, rank: Int) -> some View {
        let tint: Color = {
            switch rank {
            case 1: return Color(hex: 0xFFC74A)
            case 2: return Color(hex: 0xC5D0DA)
            case 3: return Color(hex: 0xC26B3F)
            default: return Brand.Color.textTertiary
            }
        }()
        return VStack(spacing: 6) {
            if let row {
                Text("@\(row.handle)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .lineLimit(1)
                Text("\(row.points.formatted(.number))")
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint, lineWidth: 1))
                Text("\(rank)")
                    .font(.system(size: 28, weight: .heavy, design: .monospaced))
                    .foregroundStyle(tint)
                    .padding(.top, 8)
            }
            .frame(height: height)
        }
        .frame(maxWidth: .infinity)
    }

    private func leaderRow(_ row: LeaderRow) -> some View {
        HStack(spacing: 12) {
            Text("\(row.rank ?? 0)")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(row.isMe ? Brand.Color.cyan : Brand.Color.textTertiary)
                .monospacedDigit()
                .frame(width: 30, alignment: .leading)
            Text("@\(row.handle)")
                .font(.system(size: 14, weight: row.isMe ? .bold : .regular, design: .monospaced))
                .foregroundStyle(Brand.Color.textPrimary)
            Spacer()
            Text("\(row.points.formatted(.number))")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(row.isMe ? Brand.Color.cyan : Brand.Color.textPrimary)
                .monospacedDigit()
            if row.isMe {
                Text("YOU")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Brand.Color.cyan, in: .capsule)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct LeaderRow: Identifiable, Equatable {
    var rank: Int?
    let handle: String
    let points: Int
    let countries: Int
    var isMe: Bool = false
    var id: String { handle }
}

// MARK: - Share card

struct ShareCardSheet: View {
    let stats: ProfileStats
    let handle: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                shareCardArtboard
                    .padding(.top, 24)
                Spacer()
                ShareLink(
                    item: shareImage,
                    preview: SharePreview("Tailspot · @\(handle)", image: shareImage)
                ) {
                    Text("Share")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Brand.Color.cyan, in: .rect(cornerRadius: 12))
                        .padding(.horizontal, 24)
                }
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brand.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    /// Pre-rendered Image of the share card. ImageRenderer runs on the
    /// MainActor and stamps the live SwiftUI view into a UIImage, which
    /// ShareLink can hand off to any share target.
    private var shareImage: Image {
        let renderer = ImageRenderer(content: shareCardArtboard.frame(width: 360, height: 540))
        renderer.scale = 3
        if let ui = renderer.uiImage {
            return Image(uiImage: ui)
        }
        return Image(systemName: "airplane")
    }

    /// The shareable artboard itself — also rendered to screen
    /// before sharing so the user previews exactly what they're
    /// about to send.
    private var shareCardArtboard: some View {
        ZStack {
            LinearGradient(
                colors: [Brand.Color.bgElevated, Brand.Color.bgSurface],
                startPoint: .top, endPoint: .bottom
            )
            // Subtle cyan radial bloom.
            RadialGradient(
                gradient: Gradient(colors: [Brand.Color.cyan.opacity(0.20), .clear]),
                center: UnitPoint(x: 0.5, y: 0.30),
                startRadius: 0,
                endRadius: 280
            )
            .blendMode(.screen)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "airplane")
                        .foregroundStyle(Brand.Color.cyan)
                        .font(.system(size: 20))
                    Text("TAILSPOT")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(Brand.Color.textPrimary)
                    Spacer()
                    Text("@\(handle)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Brand.Color.cyan)
                }
                Spacer(minLength: 0)
                Text(stats.totalPoints.formatted(.number))
                    .font(.system(size: 64, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .monospacedDigit()
                Text("TOTAL POINTS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(Brand.Color.textTertiary)
                Divider().background(Brand.Color.textTertiary.opacity(0.3))
                HStack {
                    statTile(label: "Catches", value: stats.totalCatches)
                    Spacer()
                    statTile(label: "Unique",  value: stats.uniqueAirframes)
                    Spacer()
                    statTile(label: "Rare+",   value: stats.rarePlusUnique, tint: Brand.Color.alertAdvisory)
                }
                Spacer(minLength: 0)
                Text("Catch every plane you see. Build a hangar of them.")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
            }
            .padding(22)
        }
        .frame(width: 320, height: 480)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Brand.Color.cyan.opacity(0.40), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
    }

    private func statTile(label: String, value: Int, tint: Color = Brand.Color.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 22, weight: .heavy, design: .monospaced))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(Brand.Color.textTertiary)
        }
    }
}

// MARK: - Public Hangar

struct PublicHangarScreen: View {
    let handle: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Text("Public hangars ship with the backend. Previewing layout only.")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textTertiary)
                    .padding(.bottom, 8)
                Text("RECENT CATCHES")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textTertiary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(0..<6, id: \.self) { _ in
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Brand.Color.bgElevated)
                            VStack {
                                Image(systemName: "airplane")
                                    .font(.system(size: 28, weight: .light))
                                    .foregroundStyle(Brand.Color.textTertiary)
                                Text("Mock entry")
                                    .font(Brand.Font.caption)
                                    .foregroundStyle(Brand.Color.textTertiary)
                            }
                        }
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    }
                }
            }
            .padding(16)
        }
        .background(Brand.Color.bgPrimary.ignoresSafeArea())
        .navigationTitle("@\(handle)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Brand.Color.bgElevated)
                    .frame(width: 56, height: 56)
                    .overlay(
                        Text(String(handle.prefix(2)).uppercased())
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundStyle(Brand.Color.cyan)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("@\(handle)")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(Brand.Color.textPrimary)
                    Text("128 catches · 88 unique · 14 rare+")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Button("Follow") {}
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.Color.cyan)
                Button("Visit hangar") {}
                    .buttonStyle(.bordered)
                    .tint(Brand.Color.textPrimary)
            }
        }
    }
}

#Preview("Leaderboard") {
    NavigationStack { LeaderboardScreen() }
        .modelContainer(for: Catch.self, inMemory: true)
}

#Preview("Share") {
    ShareCardSheet(
        stats: ProfileStats(catches: []),
        handle: "preview"
    )
}

#Preview("Public Hangar") {
    NavigationStack {
        PublicHangarScreen(handle: "vapor_trail")
    }
}
