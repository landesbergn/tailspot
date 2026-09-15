#if DEBUG

import SwiftUI

/// Fixture-only exploration of the Catch / Leaders / Challenges hierarchy.
/// Launch with `-competitionPOC` and optionally
/// `-competitionPOCSection account|leaders|challenges`.
struct ProfileCompetitionPOC: View {
    @State private var presentedSheet: CompetitionPOCPresentation?

    init() {
        let args = ProcessInfo.processInfo.arguments
        let requested: CompetitionPOCPresentation?
        if let flag = args.firstIndex(of: "-competitionPOCSection"),
           args.indices.contains(flag + 1) {
            requested = CompetitionPOCPresentation(rawValue: args[flag + 1])
        } else {
            requested = nil
        }
        _presentedSheet = State(initialValue: requested)
    }

    var body: some View {
        CompetitionPOCCatchScreen(
            openAccount: { presentedSheet = .account },
            openLeaders: { presentedSheet = .leaders }
        )
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .account:
                CompetitionPOCAccountMenu()
            case .leaders:
                CompetitionPOCNavigation(startAtChallenges: false)
            case .challenges:
                CompetitionPOCNavigation(startAtChallenges: true)
            }
        }
        .preferredColorScheme(.dark)
    }
}

private enum CompetitionPOCPresentation: String, Identifiable {
    case account, leaders, challenges
    var id: String { rawValue }
}

// MARK: - Catch screen shell

private struct CompetitionPOCCatchScreen: View {
    let openAccount: () -> Void
    let openLeaders: () -> Void

    var body: some View {
        ZStack {
            skyBackdrop
            aircraftScene

            VStack {
                topChrome
                Spacer()
                captureBar.padding(.bottom, 42)
            }
            .padding(.horizontal, 18)
        }
        .ignoresSafeArea()
    }

    private var skyBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x102B46), Color(hex: 0x416A83), Color(hex: 0x9BB2BE)],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Color.white.opacity(0.38), .clear],
                center: .init(x: 0.18, y: 0.25),
                startRadius: 10,
                endRadius: 260
            )
            LinearGradient(
                colors: [.clear, Brand.Color.bgSurface.opacity(0.22)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
    }

    private var aircraftScene: some View {
        GeometryReader { geometry in
            ZStack {
                Image(systemName: "airplane")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Brand.Color.bgSurface.opacity(0.78))
                    .rotationEffect(.degrees(-8))

                lockOnCorners.frame(width: 128, height: 88)

                VStack(spacing: 3) {
                    Text("UAL 184")
                        .font(Brand.Font.mono(size: 12, weight: .bold))
                        .tracking(1)
                    Text("B737 · 8.2 KM")
                        .font(Brand.Font.mono(size: 9, weight: .bold))
                        .tracking(0.7)
                }
                .foregroundStyle(Brand.Color.cyan)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Brand.Color.bgSurface.opacity(0.70), in: .rect(cornerRadius: Brand.Radius.chip))
                .offset(y: 72)

                Text("3 AIRCRAFT NEARBY")
                    .font(Brand.Font.mono(size: 10, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Brand.Color.textPrimary.opacity(0.82))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Brand.Color.bgSurface.opacity(0.58), in: .capsule)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.68)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var lockOnCorners: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 22))
                    path.addLine(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: 22, y: 0))
                }
                .stroke(Brand.Color.cyan, style: StrokeStyle(lineWidth: 2.2, lineCap: .square))
                .frame(width: 24, height: 24)
                .rotationEffect(.degrees(Double(index) * 90))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cornerAlignment(index))
            }
        }
    }

    private func cornerAlignment(_ index: Int) -> Alignment {
        switch index {
        case 0: return .topLeading
        case 1: return .topTrailing
        case 2: return .bottomTrailing
        default: return .bottomLeading
        }
    }

    private var topChrome: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("TAILSPOT")
                    .font(Brand.Font.mono(size: 13, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Brand.Color.textPrimary)
                Text("POINT AT A PLANE")
                    .font(Brand.Font.mono(size: 8, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(Brand.Color.textPrimary.opacity(0.65))
            }
            .padding(.top, 62)

            Spacer()

            Button(action: openAccount) {
                ZStack(alignment: .topTrailing) {
                    Circle()
                        .fill(Brand.Color.bgPrimary.opacity(0.72))
                        .overlay { Circle().strokeBorder(Brand.Color.textPrimary.opacity(0.10), lineWidth: 1) }
                        .frame(width: 44, height: 44)
                    Image(systemName: "person.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Brand.Color.textPrimary)
                        .frame(width: 44, height: 44)
                    notificationDot
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open account menu")
            .padding(.top, 54)
        }
    }

    private var captureBar: some View {
        HStack {
            Button {} label: {
                ZStack(alignment: .topTrailing) {
                    navigationChip
                    HangarGlyph(lineWidth: 2, tint: Brand.Color.textPrimary.opacity(0.9))
                        .frame(width: 26, height: 26)
                        .frame(width: 56, height: 56)
                    Text("42")
                        .font(Brand.Font.mono(size: 10, weight: .bold))
                        .foregroundStyle(Brand.Color.bgPrimary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Brand.Color.alertNormal, in: .capsule)
                        .offset(x: 4, y: -4)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open hangar, 42 catches")

            Spacer()

            Button {} label: {
                ZStack {
                    Circle().fill(Brand.Color.bgPrimary.opacity(0.72)).frame(width: 72, height: 72)
                    Circle().strokeBorder(Brand.Color.cyan, lineWidth: 2.5).frame(width: 72, height: 72)
                    Circle().fill(Brand.Color.cyan.opacity(0.15)).frame(width: 60, height: 60)
                    Text("CAPTURE")
                        .font(Brand.Font.mono(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Brand.Color.cyan)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Capture aircraft")

            Spacer()

            Button(action: openLeaders) {
                ZStack(alignment: .topTrailing) {
                    navigationChip
                    Image(systemName: "list.number")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(Brand.Color.textPrimary.opacity(0.92))
                        .frame(width: 56, height: 56)
                    notificationDot.offset(x: 2, y: -2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open leaders")
        }
        .padding(.horizontal, 10)
    }

    private var navigationChip: some View {
        RoundedRectangle(cornerRadius: Brand.Radius.card)
            .fill(Brand.Color.bgPrimary.opacity(0.72))
            .overlay {
                RoundedRectangle(cornerRadius: Brand.Radius.card)
                    .strokeBorder(Brand.Color.textPrimary.opacity(0.10), lineWidth: 1)
            }
            .frame(width: 56, height: 56)
    }

    private var notificationDot: some View {
        Circle()
            .fill(Brand.Color.cyan)
            .frame(width: 9, height: 9)
            .overlay { Circle().strokeBorder(Brand.Color.bgSurface, lineWidth: 2) }
    }
}

// MARK: - Account sheet

private struct CompetitionPOCAccountMenu: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                GlassEffectContainer {
                    VStack(spacing: 14) {
                        identitySummary
                        challengeEntry
                        utilityRows
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(CompetitionPOCBackdrop())
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {} label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share Tailspot")
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var identitySummary: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Brand.Color.bgPrimary)
                Circle().strokeBorder(Brand.Color.cyan.opacity(0.42), lineWidth: 1.5)
                Text("NO")
                    .font(Brand.Font.mono(size: 16, weight: .bold))
                    .foregroundStyle(Brand.Color.cyan)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text("@noah")
                    .font(Brand.Font.mono(size: 18, weight: .bold, relativeTo: .headline))
                    .foregroundStyle(Brand.Color.textPrimary)
                Text("42 catches · 8 trophies")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("1,370")
                    .font(Brand.Font.mono(size: 18, weight: .bold, relativeTo: .headline))
                    .foregroundStyle(Brand.Color.cyan)
                Text("12TH GLOBAL")
                    .font(Brand.Font.mono(size: 8, weight: .bold, relativeTo: .caption2))
                    .tracking(0.8)
                    .foregroundStyle(Brand.Color.textTertiary)
            }
        }
        .padding(16)
        .glassEffect(CompetitionPOCStyle.brandGlass, in: .rect(cornerRadius: Brand.Radius.card))
    }

    private var challengeEntry: some View {
        NavigationLink {
            challengesDestination
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: Brand.Radius.chip)
                        .fill(Brand.Color.cyan.opacity(0.14))
                        .frame(width: 46, height: 46)
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Brand.Color.cyan)
                        .frame(width: 46, height: 46)
                    Text("1")
                        .font(Brand.Font.mono(size: 8, weight: .bold))
                        .foregroundStyle(Brand.Color.bgPrimary)
                        .frame(width: 17, height: 17)
                        .background(Brand.Color.cyan, in: .circle)
                        .offset(x: 4, y: -4)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text("Challenges")
                            .font(Brand.Font.cardTitle)
                            .foregroundStyle(Brand.Color.textPrimary)
                        Text("NEW")
                            .font(Brand.Font.mono(size: 8, weight: .bold, relativeTo: .caption2))
                            .tracking(0.8)
                            .foregroundStyle(Brand.Color.bgPrimary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Brand.Color.cyan, in: .capsule)
                    }
                    Text("Weekend Flyoff · 2nd · 48m left")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.Color.textTertiary)
            }
            .padding(14)
            .glassEffect(CompetitionPOCStyle.brandGlass, in: .rect(cornerRadius: Brand.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Brand.Radius.card)
                    .strokeBorder(Brand.Color.cyan.opacity(0.18), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var challengesDestination: some View {
        ProfilePOCChallenges()
            .background(CompetitionPOCBackdrop())
            .navigationTitle("Challenges")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {} label: { Image(systemName: "plus") }
                        .accessibilityLabel("Create challenge")
                }
            }
    }

    private var utilityRows: some View {
        VStack(spacing: 0) {
            utilityRow("Map", symbol: "map")
            divider
            utilityRow("Rarity guide", symbol: "diamond")
            divider
            utilityRow("Settings", symbol: "gear")
        }
        .background(Brand.Color.bgElevated.opacity(0.75), in: .rect(cornerRadius: Brand.Radius.card))
    }

    private func utilityRow(_ title: String, symbol: String) -> some View {
        Button {} label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Brand.Color.cyan)
                    .frame(width: 24)
                Text(title)
                    .font(Brand.Font.body)
                    .foregroundStyle(Brand.Color.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.Color.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle()
            .fill(Brand.Color.bgPrimary.opacity(0.5))
            .frame(height: 1)
            .padding(.leading, 52)
    }
}

// MARK: - Leaders → Challenges stack

private enum CompetitionPOCRoute: Hashable { case challenges }

private struct CompetitionPOCNavigation: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: [CompetitionPOCRoute]

    init(startAtChallenges: Bool) {
        _path = State(initialValue: startAtChallenges ? [.challenges] : [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            ProfilePOCLeaders()
                .background(CompetitionPOCBackdrop())
                .navigationTitle("Leaders")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: CompetitionPOCRoute.challenges) {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "flag.checkered")
                                Circle()
                                    .fill(Brand.Color.cyan)
                                    .frame(width: 7, height: 7)
                                    .overlay { Circle().strokeBorder(Brand.Color.bgPrimary, lineWidth: 1.5) }
                                    .offset(x: 4, y: -4)
                            }
                        }
                        .accessibilityLabel("Challenges, one active")
                    }
                }
                .navigationDestination(for: CompetitionPOCRoute.self) { _ in
                    ProfilePOCChallenges()
                        .background(CompetitionPOCBackdrop())
                        .navigationTitle("Challenges")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {} label: { Image(systemName: "plus") }
                                    .accessibilityLabel("Create challenge")
                            }
                        }
                }
        }
    }
}

// MARK: - Challenges hub fixture

private struct ProfilePOCChallenges: View {
    var body: some View {
        ScrollView {
            GlassEffectContainer {
                VStack(alignment: .leading, spacing: 16) {
                    activeChallenge
                    sectionLabel("ON DECK")
                    inviteCard
                    sectionLabel("FLIGHT LOG")
                    historyCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var activeChallenge: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("IN FLIGHT", systemImage: "airplane")
                    .font(Brand.Font.mono(size: 10, weight: .bold, relativeTo: .caption2))
                    .tracking(1.1)
                    .foregroundStyle(Brand.Color.cyan)
                Spacer()
                Text("48M LEFT")
                    .font(Brand.Font.mono(size: 10, weight: .bold, relativeTo: .caption2))
                    .tracking(1.1)
                    .foregroundStyle(Brand.Color.textSecondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Weekend Flyoff")
                    .brandDisplayFont()
                    .foregroundStyle(Brand.Color.textPrimary)
                Text("5 spotters · ends today at 6:00 PM")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
            }

            HStack(spacing: 0) {
                challengeMetric("2nd", label: "PLACE", color: Brand.Color.podiumSilver)
                challengeMetric("380", label: "POINTS", color: Brand.Color.cyan)
                challengeMetric("11", label: "CATCHES", color: Brand.Color.textPrimary)
            }

            HStack {
                Text("24 PTS BEHIND @MAYA")
                    .font(Brand.Font.mono(size: 9, weight: .bold, relativeTo: .caption2))
                    .tracking(0.9)
                    .foregroundStyle(Brand.Color.textSecondary)
                Spacer()
                Label("Standings", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
                    .font(Brand.Font.button)
                    .foregroundStyle(Brand.Color.bgPrimary)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(Brand.Color.cyan, in: .rect(cornerRadius: Brand.Radius.row))
        }
        .padding(18)
        .background(Brand.Color.cyan.opacity(0.07), in: .rect(cornerRadius: Brand.Radius.card))
        .glassEffect(CompetitionPOCStyle.brandGlass, in: .rect(cornerRadius: Brand.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Brand.Radius.card)
                .strokeBorder(Brand.Color.cyan.opacity(0.22), lineWidth: 1)
        }
    }

    private var inviteCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: Brand.Radius.chip)
                    .fill(Brand.Color.cyan.opacity(0.13))
                Image(systemName: "paperplane.fill").foregroundStyle(Brand.Color.cyan)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text("Bay Area Spotters")
                    .font(Brand.Font.cardTitle)
                    .foregroundStyle(Brand.Color.textPrimary)
                Text("Invited by @eli · starts tomorrow")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
            }
            Spacer()
            Text("JOIN")
                .font(Brand.Font.mono(size: 10, weight: .bold, relativeTo: .caption2))
                .tracking(0.8)
                .foregroundStyle(Brand.Color.cyan)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Brand.Color.cyan.opacity(0.12), in: .capsule)
        }
        .padding(14)
        .glassEffect(CompetitionPOCStyle.brandGlass, in: .rect(cornerRadius: Brand.Radius.card))
    }

    private var historyCard: some View {
        VStack(spacing: 0) {
            historyRow(place: "1", medal: Brand.Color.podiumGold,
                       title: "Golden Hour", detail: "Won · 620 pts · Aug 18")
            Rectangle().fill(Brand.Color.bgPrimary.opacity(0.5)).frame(height: 1).padding(.leading, 58)
            historyRow(place: "3", medal: Brand.Color.podiumBronze,
                       title: "Sunday Circuit", detail: "3rd of 6 · 410 pts · Aug 10")
        }
        .background(Brand.Color.bgElevated.opacity(0.75), in: .rect(cornerRadius: Brand.Radius.card))
    }

    private func historyRow(place: String, medal: Color, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(medal.opacity(0.15))
                Text(place)
                    .font(Brand.Font.mono(size: 13, weight: .bold, relativeTo: .footnote))
                    .foregroundStyle(medal)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Brand.Font.body.weight(.semibold)).foregroundStyle(Brand.Color.textPrimary)
                Text(detail).font(Brand.Font.caption).foregroundStyle(Brand.Color.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Brand.Color.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func challengeMetric(_ value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(Brand.Font.mono(size: 23, weight: .bold, relativeTo: .title3))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(Brand.Font.mono(size: 8, weight: .semibold, relativeTo: .caption2))
                .tracking(1.1)
                .foregroundStyle(Brand.Color.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Global leaders fixture

private struct ProfilePOCLeaders: View {
    @State private var selectedWindow: LeaderboardWindow = .week

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                LeaderboardWindowSwitcher(selection: $selectedWindow)
                Text("RESETS MONDAY · 1D 8H LEFT")
                    .font(Brand.Font.mono(size: 10, weight: .semibold, relativeTo: .caption2))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textTertiary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    championBanner
                    podium
                    sectionLabel("TOP SPOTTERS")
                    standings
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var championBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "laurel.leading").foregroundStyle(Brand.Color.podiumGold)
            VStack(alignment: .leading, spacing: 2) {
                Text("LAST WEEK'S CHAMPION")
                    .font(Brand.Font.mono(size: 9, weight: .bold, relativeTo: .caption2))
                    .tracking(1.1)
                    .foregroundStyle(Brand.Color.podiumGold)
                Text("@maya · 1,120 PTS")
                    .font(Brand.Font.mono(size: 13, weight: .bold, relativeTo: .footnote))
                    .foregroundStyle(Brand.Color.textPrimary)
            }
            Spacer()
            Image(systemName: "laurel.trailing").foregroundStyle(Brand.Color.podiumGold)
        }
        .padding(14)
        .background(Brand.Color.podiumGold.opacity(0.11), in: .rect(cornerRadius: Brand.Radius.row))
        .overlay {
            RoundedRectangle(cornerRadius: Brand.Radius.row)
                .strokeBorder(Brand.Color.podiumGold.opacity(0.22), lineWidth: 1)
        }
    }

    private var podium: some View {
        HStack(alignment: .bottom, spacing: 8) {
            podiumPlace(2, "@eli", "890", Brand.Color.podiumSilver, 88)
            podiumPlace(1, "@maya", "1,040", Brand.Color.podiumGold, 112)
            podiumPlace(3, "@jetset", "760", Brand.Color.podiumBronze, 72)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func podiumPlace(_ place: Int, _ handle: String, _ points: String, _ color: Color, _ height: CGFloat) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(color.opacity(0.14))
                Text("\(place)")
                    .font(Brand.Font.mono(size: 17, weight: .bold, relativeTo: .body))
                    .foregroundStyle(color)
            }
            .frame(width: 38, height: 38)
            Text(handle)
                .font(Brand.Font.mono(size: 11, weight: .bold, relativeTo: .caption))
                .foregroundStyle(Brand.Color.textPrimary)
            Text("\(points) PTS")
                .font(Brand.Font.mono(size: 9, weight: .semibold, relativeTo: .caption2))
                .foregroundStyle(color)
            RoundedRectangle(cornerRadius: Brand.Radius.row)
                .fill(color.opacity(0.13))
                .frame(height: height)
                .overlay(alignment: .top) { Rectangle().fill(color).frame(height: 2) }
        }
        .frame(maxWidth: .infinity)
    }

    private var standings: some View {
        VStack(spacing: 0) {
            leaderRow("4", "@skywatch", "620", "19")
            divider
            leaderRow("12", "@noah", "380", "11", isMe: true)
            divider
            leaderRow("13", "@avgeek", "356", "14")
        }
        .background(Brand.Color.bgElevated.opacity(0.75), in: .rect(cornerRadius: Brand.Radius.card))
    }

    private func leaderRow(_ rank: String, _ handle: String, _ points: String, _ catches: String, isMe: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(rank)
                .font(Brand.Font.mono(size: 15, weight: .bold, relativeTo: .body))
                .foregroundStyle(isMe ? Brand.Color.cyan : Brand.Color.textSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(handle)
                        .font(Brand.Font.mono(size: 13, weight: .bold, relativeTo: .footnote))
                        .foregroundStyle(Brand.Color.textPrimary)
                    if isMe {
                        Text("YOU")
                            .font(Brand.Font.mono(size: 8, weight: .bold, relativeTo: .caption2))
                            .foregroundStyle(Brand.Color.bgPrimary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Brand.Color.cyan, in: .capsule)
                    }
                }
                Text("\(catches) catches")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textTertiary)
            }
            Spacer()
            Text("\(points) PTS")
                .font(Brand.Font.mono(size: 12, weight: .bold, relativeTo: .caption))
                .foregroundStyle(isMe ? Brand.Color.cyan : Brand.Color.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(isMe ? Brand.Color.cyan.opacity(0.07) : .clear)
    }

    private var divider: some View {
        Rectangle().fill(Brand.Color.bgPrimary.opacity(0.5)).frame(height: 1).padding(.leading, 50)
    }
}

private enum CompetitionPOCStyle {
    static let brandGlass: Glass = .regular.tint(Brand.Color.bgElevated.opacity(0.88))
}

private struct CompetitionPOCBackdrop: View {
    var body: some View {
        ZStack {
            Brand.Color.bgPrimary
            RadialGradient(
                colors: [Brand.Color.cyan.opacity(0.10), .clear],
                center: .init(x: 0.85, y: 0.05),
                startRadius: 10,
                endRadius: 420
            )
            RadialGradient(
                colors: [Brand.Color.alertAdvisory.opacity(0.05), .clear],
                center: .init(x: 0.1, y: 0.75),
                startRadius: 10,
                endRadius: 380
            )
        }
        .ignoresSafeArea()
    }
}

private func sectionLabel(_ title: String) -> some View {
    Text(title)
        .font(Brand.Font.mono(size: 10, weight: .semibold, relativeTo: .caption2))
        .tracking(1.2)
        .foregroundStyle(Brand.Color.textTertiary)
        .padding(.horizontal, 4)
}

#endif
