//
//  PublicScreens.swift
//  Tailspot
//
//  Public surfaces:
//
//   - LeaderboardScreen — live global leaderboard from the backend.
//     Shows rank/handle/points/catches, highlights "me" row (works
//     even handle-less, with a "claim a handle to appear" hint).
//     Loading / error / empty states follow Brand patterns.
//     Pull-to-refresh supported.
//
//   - ShareCardSheet — shareable card composed in SwiftUI, handed
//     to ShareLink as an Image-renderable view.
//
//  PublicHangarScreen was removed (backend not ready; the NavigationLink
//  it was reachable via has also been removed).
//

import SwiftUI
import SwiftData

// MARK: - Leaderboard (live)

struct LeaderboardScreen: View {
    @AppStorage(SpotterHandle.storageKey) private var localHandle: String = SpotterHandle.defaultPlaceholder

    // Fetch total local points so we can show them in the "me" row
    // when the backend hasn't replied yet, or when not registered.
    @Query private var catches: [Catch]

    // MARK: State
    @State private var entries: [LeaderboardEntry] = []
    @State private var me: MyStanding? = nil
    @State private var loadState: LoadState = .idle
    @State private var isRefreshing = false

    private let client = TailspotAccountClient()

    enum LoadState {
        case idle, loading, loaded, error(String)
    }

    var body: some View {
        List {
            switch loadState {
            case .idle, .loading:
                loadingSection
            case .error(let msg):
                errorSection(msg)
            case .loaded:
                if entries.isEmpty {
                    emptySection
                } else {
                    if entries.count >= 3 {
                        Section {
                            podium
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                    }
                    rankSection
                    meHintSection
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Leaderboard")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if case .idle = loadState { await load() } }
    }

    // MARK: - Load

    private func load() async {
        isRefreshing = true
        if case .idle = loadState { loadState = .loading }
        do {
            let response = try await client.leaderboard()
            entries = response.entries
            me = response.me
            loadState = .loaded
        } catch {
            loadState = .error(error.localizedDescription)
        }
        isRefreshing = false
    }

    // MARK: - Sections

    private var loadingSection: some View {
        Section {
            HStack {
                Spacer()
                ProgressView()
                    .tint(Brand.Color.cyan)
                    .padding(.vertical, 32)
                Spacer()
            }
            .listRowBackground(Color.clear)
        }
    }

    private func errorSection(_ msg: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn't load leaderboard", systemImage: "wifi.slash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.Color.alertCaution)
                Text(msg)
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
                Button("Try again") {
                    loadState = .idle
                    Task { await load() }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.Color.cyan)
            }
            .padding(.vertical, 6)
        }
    }

    private var emptySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("No handles yet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
                Text("Be the first to claim a handle in Settings → Identity to appear here.")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
            }
            .padding(.vertical, 6)
        }
    }

    /// Top-3 podium block.
    private var podium: some View {
        HStack(alignment: .bottom, spacing: 8) {
            podiumColumn(entry: entries.first(where: { $0.rank == 2 }), height: 90,  rank: 2)
            podiumColumn(entry: entries.first(where: { $0.rank == 1 }), height: 130, rank: 1)
            podiumColumn(entry: entries.first(where: { $0.rank == 3 }), height: 70,  rank: 3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(Brand.Color.bgElevated)
    }

    private func podiumColumn(entry: LeaderboardEntry?, height: CGFloat, rank: Int) -> some View {
        let tint: Color = {
            switch rank {
            case 1: return Color(hex: 0xFFC74A)
            case 2: return Color(hex: 0xC5D0DA)
            case 3: return Color(hex: 0xC26B3F)
            default: return Brand.Color.textTertiary
            }
        }()
        return VStack(spacing: 6) {
            if let entry {
                Text("@\(entry.handle)")
                    .font(Brand.Font.mono(size: 10, weight: .bold))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .lineLimit(1)
                Text("\(entry.points.formatted(.number))")
                    .font(Brand.Font.mono(size: 13, weight: .heavy))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint, lineWidth: 1))
                Text("\(rank)")
                    .font(Brand.Font.mono(size: 28, weight: .heavy))
                    .foregroundStyle(tint)
                    .padding(.top, 8)
            }
            .frame(height: height)
        }
        .frame(maxWidth: .infinity)
    }

    /// Full ranked list.
    @ViewBuilder
    private var rankSection: some View {
        Section {
            ForEach(entries) { entry in
                leaderRow(entry)
            }
        } footer: {
            Text("Anonymous global. Handles are public; identities aren't tied to Apple ID.")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textTertiary)
        }
    }

    private func leaderRow(_ entry: LeaderboardEntry) -> some View {
        let isMe = isMeEntry(entry)
        return HStack(spacing: 12) {
            Text("\(entry.rank)")
                .font(Brand.Font.mono(size: 14, weight: .bold))
                .foregroundStyle(isMe ? Brand.Color.cyan : Brand.Color.textTertiary)
                .monospacedDigit()
                .frame(width: 30, alignment: .leading)
            Text("@\(entry.handle)")
                .font(Brand.Font.mono(size: 14, weight: isMe ? .bold : .regular))
                .foregroundStyle(Brand.Color.textPrimary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(entry.points.formatted(.number))")
                    .font(Brand.Font.mono(size: 13, weight: .bold))
                    .foregroundStyle(isMe ? Brand.Color.cyan : Brand.Color.textPrimary)
                    .monospacedDigit()
                Text("\(entry.catches) catch\(entry.catches == 1 ? "" : "es")")
                    .font(Brand.Font.mono(size: 10))
                    .foregroundStyle(Brand.Color.textTertiary)
            }
            if isMe {
                Text("YOU")
                    .font(Brand.Font.mono(size: 9, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Brand.Color.cyan, in: .capsule)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isMe
            ? Brand.Color.cyan.opacity(0.12)
            : Color.clear)
    }

    /// True when this entry is for the current user's handle.
    private func isMeEntry(_ entry: LeaderboardEntry) -> Bool {
        entry.handle.lowercased() == localHandle.lowercased()
    }

    /// "Me" section shown below the ranked list: either the me row from the
    /// API (when the device has a handle), or a prompt to claim one.
    @ViewBuilder
    private var meHintSection: some View {
        let myLocalPoints = ProfileStats(catches: catches).totalPoints
        let hasHandle = !localHandle.isEmpty && localHandle != SpotterHandle.defaultPlaceholder

        if let meStanding = me {
            // Server confirmed our standing — show it.
            Section {
                HStack(spacing: 12) {
                    Text("\(meStanding.rank)")
                        .font(Brand.Font.mono(size: 14, weight: .bold))
                        .foregroundStyle(Brand.Color.cyan)
                        .monospacedDigit()
                        .frame(width: 30, alignment: .leading)
                    Text(hasHandle ? "@\(localHandle)" : "(you)")
                        .font(Brand.Font.mono(size: 14, weight: .bold))
                        .foregroundStyle(Brand.Color.textPrimary)
                    Spacer()
                    Text("\(meStanding.points.formatted(.number))")
                        .font(Brand.Font.mono(size: 13, weight: .bold))
                        .foregroundStyle(Brand.Color.cyan)
                        .monospacedDigit()
                    Text("YOU")
                        .font(Brand.Font.mono(size: 9, weight: .bold))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Brand.Color.cyan, in: .capsule)
                }
                .padding(.vertical, 2)
                .listRowBackground(Brand.Color.cyan.opacity(0.12))
                if !hasHandle {
                    Text("Claim a handle in Settings → Identity to appear in the list above.")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                }
            } header: {
                Text("Your standing")
            }
        } else if !hasHandle {
            // Not registered yet or no handle — hint.
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("You have \(myLocalPoints.formatted(.number)) points locally")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Brand.Color.textPrimary)
                    Text("Claim a handle in Settings → Identity to appear on the leaderboard.")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Your standing")
            }
        }
    }
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
                        .font(Brand.Font.mono(size: 18, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(Brand.Color.textPrimary)
                    Spacer()
                    Text("@\(handle)")
                        .font(Brand.Font.mono(size: 13, weight: .bold))
                        .foregroundStyle(Brand.Color.cyan)
                }
                Spacer(minLength: 0)
                Text(stats.totalPoints.formatted(.number))
                    .font(Brand.Font.mono(size: 64, weight: .heavy))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .monospacedDigit()
                Text("TOTAL POINTS")
                    .font(Brand.Font.mono(size: 10, weight: .semibold))
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
                .font(Brand.Font.mono(size: 22, weight: .heavy))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(label.uppercased())
                .font(Brand.Font.mono(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Brand.Color.textTertiary)
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
