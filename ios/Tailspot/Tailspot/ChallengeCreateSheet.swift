//
//  ChallengeCreateSheet.swift
//  Tailspot
//
//  Create a challenge (spec §4.1): a prefilled name, Now or Schedule, one
//  of four durations (both as the same glass slider), a computed end line,
//  Create. Utility chrome: a branded inset-grouped List inside its own
//  NavigationStack, like Settings. The creator is the first participant;
//  on success the caller receives the detail and pushes it, where the
//  inline INVITE card prompts for the first invite.
//

import SwiftUI

struct ChallengeCreateSheet: View {
    @Environment(ChallengesModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SpotterHandle.storageKey) private var handle: String = SpotterHandle.defaultPlaceholder

    let onCreated: (ChallengeDetail) -> Void

    enum StartMode: String, CaseIterable, Identifiable {
        case now, scheduled
        var id: String { rawValue }
        var label: String { self == .now ? "Starts now" : "Schedule" }
        var short: String { self == .now ? "NOW" : "SCHEDULE" }
    }

    enum Duration: String, CaseIterable, Identifiable {
        case h1 = "1h", h24 = "24h", d3 = "3d", d7 = "7d"
        var id: String { rawValue }
        var label: String { ChallengeCopy.durationLabel(rawValue) }
        var short: String { rawValue.uppercased() }
        var seconds: TimeInterval { ChallengeDurations.seconds(for: rawValue) }
    }

    @State private var name: String
    @State private var startMode: StartMode = .now
    @State private var scheduledAt: Date
    @State private var duration: Duration = .h24
    @State private var isSubmitting = false
    /// The start the sheet last moved forward on its own (see
    /// `keepScheduledStartValid`). The note under the picker shows only
    /// while the picker still holds exactly that value; any manual change
    /// makes it moot.
    @State private var autoMovedTo: Date?
    @State private var error: ChallengesError?

    static let nameMin = 3
    static let nameMax = 24
    /// The server's rule is "at least 15 minutes ahead", checked when the
    /// request ARRIVES; the client checks when the form renders. A start
    /// picked exactly 15 minutes out is therefore already stale by the time
    /// the user taps Create, and the create 422s on a form that looked
    /// valid. One minute of cushion makes that boundary unreachable — the
    /// picker can't offer it and validation won't pass it.
    static let minLead: TimeInterval = 16 * 60
    /// The picker floor and the validation message in minutes, so the copy
    /// can never drift from the rule.
    static var minLeadMinutes: Int { Int(minLead / 60) }
    static let maxLead: TimeInterval = 14 * 86_400

    /// `_debugName` / `_debugStartMode` / `_debugScheduledAt` seed the
    /// snapshot harness.
    init(onCreated: @escaping (ChallengeDetail) -> Void,
         _debugName: String? = nil,
         _debugStartMode: StartMode = .now,
         _debugScheduledAt: Date? = nil,
         _debugNow: Date = Date()) {
        self.onCreated = onCreated
        _name = State(initialValue: _debugName ?? ChallengeCopy.suggestedName(for: _debugNow))
        _startMode = State(initialValue: _debugStartMode)
        // Default schedule: the next whole hour at least 15 minutes out.
        let next = Self.nextWholeHour(after: _debugNow.addingTimeInterval(Self.minLead))
        _scheduledAt = State(initialValue: _debugScheduledAt ?? next)
    }

    static func nextWholeHour(after date: Date, calendar: Calendar = .current) -> Date {
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        let floor = calendar.date(from: comps) ?? date
        return floor <= date ? floor.addingTimeInterval(3600) : floor
    }

    // MARK: Derived

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameValid: Bool { (Self.nameMin...Self.nameMax).contains(trimmedName.count) }

    private var startsAt: Date { startMode == .now ? model.now() : scheduledAt }
    private var endsAt: Date { startsAt.addingTimeInterval(duration.seconds) }

    private var scheduleValid: Bool {
        guard startMode == .scheduled else { return true }
        return Self.isValidLead(scheduledAt.timeIntervalSince(model.now()))
    }

    /// Moves a scheduled start that has drifted inside the notice window to
    /// the earliest start that works, and remembers it for the note.
    private func keepScheduledStartValid() {
        guard let fixed = Self.clampedStart(scheduledAt, now: model.now()) else { return }
        scheduledAt = fixed
        autoMovedTo = fixed
    }

    /// Slack added when moving a stale start: landing exactly on the limit
    /// would go stale again within the minute (before the next 15 s
    /// re-check, and before the request reaches the server).
    static let clampSlack: TimeInterval = 60

    /// A valid start if `start` is too soon, else nil — the first whole
    /// minute at least `minLead + clampSlack` out. Too far out is not
    /// clamped: the picker can't offer it, and moving someone's chosen day
    /// back would be a bigger surprise than a message.
    static func clampedStart(_ start: Date, now: Date, calendar: Calendar = .current) -> Date? {
        guard start.timeIntervalSince(now) < minLead else { return nil }
        return nextMinute(after: now.addingTimeInterval(minLead + clampSlack), calendar: calendar)
    }

    static func autoMovedNote(to date: Date, now: Date, calendar: Calendar = .current) -> String {
        "Moved to \(clock(date, now: now, calendar: calendar)): starts need at least 15 minutes' notice so friends can join."
    }

    /// The name's only visible rule: say something once it's too long.
    static func isOverLimit(_ trimmed: String) -> Bool { trimmed.count > nameMax }

    static func overLimitMessage(_ trimmed: String) -> String {
        "Too long: \(trimmed.count)/\(nameMax) characters."
    }

    /// Why a scheduled start can't be used, in words, or nil when it can.
    /// The picker's range is fixed when the sheet renders, so a start that
    /// was fine can go stale while the sheet sits open — say which rule it
    /// broke and name the time that would work, not just the bounds.
    static func scheduleProblem(start: Date, now: Date,
                                calendar: Calendar = .current) -> String? {
        let lead = start.timeIntervalSince(now)
        if lead < minLead {
            let earliest = nextMinute(after: now.addingTimeInterval(minLead), calendar: calendar)
            return "Too soon. Friends need at least 15 minutes to join, so pick \(clock(earliest, now: now, calendar: calendar)) or later."
        }
        if lead > maxLead {
            let latest = now.addingTimeInterval(maxLead)
            return "Too far out. Challenges can start up to 14 days ahead, so pick \(clock(latest, now: now, calendar: calendar)) or earlier."
        }
        return nil
    }

    /// The first whole minute at or after `date`.
    static func nextMinute(after date: Date, calendar: Calendar = .current) -> Date {
        let floor = calendar.dateInterval(of: .minute, for: date)?.start ?? date
        return floor < date ? floor.addingTimeInterval(60) : floor
    }

    /// "5:02 PM" today, otherwise "Oct 11 at 4:45 PM".
    static func clock(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone).hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return time }
        let day = date.formatted(Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day())
        return "\(day) at \(time)"
    }

    /// Whether a start this far ahead may be submitted.
    static func isValidLead(_ lead: TimeInterval) -> Bool {
        lead >= minLead && lead <= maxLead
    }

    private var canSubmit: Bool { isHandleClaimed && nameValid && scheduleValid && !isSubmitting }

    /// Spec §4.1 step 1: no handle, no form. The claim card sits above the
    /// form and the Create button stays off until it succeeds — the server
    /// would 422 anyway, but a round trip to learn that is a bad first tap.
    private var isHandleClaimed: Bool {
        AnalyticsIdentity.isClaimedHandle(handle, placeholder: SpotterHandle.defaultPlaceholder)
    }
    @State private var claimedInline = false

    var body: some View {
        NavigationStack {
            List {
                if !isHandleClaimed && !claimedInline {
                    Section {
                        HandleClaimCard(source: "challenge_create") { claimedInline = true }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                nameSection
                startSection
                durationSection
                submitSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Brand.Color.bgPrimary.ignoresSafeArea())
            // The picker's range is fixed at render, so a start chosen at
            // the edge goes stale while the sheet sits open — the picker
            // then DISPLAYS the clamped earliest time while the state still
            // holds the stale one, and "too soon" looks like nonsense
            // (Noah's 2026-09-27 screenshot: 5:01 shown, flagged too soon).
            // Re-check every 15 s and move the state to what's on screen.
            .task(id: startMode) {
                guard startMode == .scheduled else { return }
                while !Task.isCancelled {
                    keepScheduledStartValid()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
            .navigationTitle("New challenge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: Sections

    private var nameSection: some View {
        Section {
            // One line. The limit only speaks up once it's been crossed; a
            // too-short name just leaves Create disabled.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Weekend Flyoff", text: $name)
                        .font(Brand.Font.body)
                        .foregroundStyle(Brand.Color.textPrimary)
                        .textInputAutocapitalization(.words)
                        .lineLimit(1)
                        .accessibilityLabel("Challenge name")
                    if !name.isEmpty {
                        // `.borderless` so only the glyph is the button;
                        // a plain button in a List row claims the whole row.
                        Button {
                            name = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(Brand.Color.textTertiary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Clear name")
                    }
                }
                if Self.isOverLimit(trimmedName) {
                    Text(Self.overLimitMessage(trimmedName))
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.alertCaution)
                        .monospacedDigit()
                }
            }
        } header: {
            header("NAME")
        }
        .listRowBackground(Brand.Color.bgElevated)
    }

    @ViewBuilder
    private var startSection: some View {
        Section {
            segmentedSlider(selection: $startMode, segments: StartMode.allCases,
                            title: "Start", label: \.label, short: \.short)
        } header: {
            header("START")
        }
        // The picker gets its own fully rounded card. Sharing a section
        // with the clear slider row drew a half-card with a hairline on top.
        if startMode == .scheduled {
            Section {
                DatePicker("Starts",
                           selection: $scheduledAt,
                           in: model.now().addingTimeInterval(Self.minLead)...model.now().addingTimeInterval(Self.maxLead),
                           displayedComponents: [.date, .hourAndMinute])
                    .font(Brand.Font.body)
                    .foregroundStyle(Brand.Color.textPrimary)
                    .tint(Brand.Color.cyan)
                    .listRowBackground(Brand.Color.bgElevated)
                if let problem = Self.scheduleProblem(start: scheduledAt, now: model.now()) {
                    Text(problem)
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.alertCaution)
                        .listRowBackground(Brand.Color.bgElevated)
                } else if let moved = autoMovedTo, moved == scheduledAt {
                    Text(Self.autoMovedNote(to: moved, now: model.now()))
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                        .listRowBackground(Brand.Color.bgElevated)
                }
            }
        }
    }

    private var durationSection: some View {
        Section {
            segmentedSlider(selection: $duration, segments: Duration.allCases,
                            title: "Duration", label: \.label, short: \.short)
        } header: {
            header("DURATION")
        } footer: {
            // Plain centered text under the slider, no card of its own.
            Text("\(duration.label) · \(ChallengeCopy.endsLine(endsAt: endsAt, now: model.now()))")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }

    /// The glass pill both Start and Duration use, so the two choices on
    /// this sheet read as the same kind of control. Generic over the
    /// option enum: `label` is what VoiceOver says, `short` what's drawn.
    private func segmentedSlider<Option: Hashable>(
        selection: Binding<Option>, segments: [Option], title: String,
        label: @escaping (Option) -> String, short: @escaping (Option) -> String
    ) -> some View {
        GlassSegmentedSlider(
            selection: selection,
            segments: segments,
            segmentHeight: 40,
            trackPadding: 4,
            accessibilityTitle: title,
            segmentTitle: label
        ) { option, isSelected in
            Text(short(option))
                .font(Brand.Font.mono(size: 12, weight: isSelected ? .bold : .regular, relativeTo: .caption))
                .tracking(0.8)
                .foregroundStyle(isSelected ? Brand.Color.bgPrimary : Brand.Color.textSecondary)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .listRowBackground(Color.clear)
    }

    private var submitSection: some View {
        Section {
            if let error {
                errorRow(error)
            }
            Button {
                Task { await submit() }
            } label: {
                HStack {
                    Spacer()
                    if isSubmitting {
                        ProgressView().scaleEffect(0.85).tint(Brand.Color.bgPrimary)
                    } else {
                        Text("Create challenge")
                            .font(Brand.Font.mono(size: 15, weight: .bold, relativeTo: .subheadline))
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(canSubmit ? Brand.Color.cyan : Brand.Color.bgElevated,
                            in: .rect(cornerRadius: Brand.Radius.row))
                .foregroundStyle(canSubmit ? Brand.Color.bgPrimary : Brand.Color.textTertiary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func errorRow(_ error: ChallengesError) -> some View {
        if error == .handleRequired {
            // Only reachable if the stored handle and the server disagree;
            // the claim card above the form is the normal path.
            Label("Claim a handle first — it's what other spotters see.", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.alertCaution)
                .listRowBackground(Brand.Color.bgElevated)
        } else {
            Label(ChallengeCopy.message(for: error), systemImage: "exclamationmark.circle.fill")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.alertCaution)
                .listRowBackground(Brand.Color.bgElevated)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(Brand.Font.mono(size: 10, weight: .semibold, relativeTo: .caption2))
            .tracking(1.2)
            .foregroundStyle(Brand.Color.textTertiary)
            .textCase(nil)
    }

    // MARK: Submit

    private func submit() async {
        // The 15 s re-check may not have run since the start went stale; a
        // Create tap that silently did nothing was the review's finding.
        if startMode == .scheduled { keepScheduledStartValid() }
        guard canSubmit else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        error = nil
        let request: ChallengeCreateRequest = startMode == .now
            ? .startingNow(name: trimmedName, duration: duration.rawValue)
            : .scheduled(name: trimmedName, at: scheduledAt, duration: duration.rawValue)
        do {
            let detail = try await model.create(request)
            Analytics.capture("challenge_created", [
                "challenge_id": .string(detail.challenge.id),
                "duration_preset": .string(duration.rawValue),
                "start_mode": .string(startMode.rawValue),
                "lead_minutes": .int(startMode == .now ? 0 : Int(scheduledAt.timeIntervalSince(model.now()) / 60)),
            ])
            dismiss()
            onCreated(detail)
        } catch let e as ChallengesError {
            error = e
        } catch {
            self.error = .network(error.localizedDescription)
        }
    }
}
