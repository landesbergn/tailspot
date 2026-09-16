//
//  ChallengeCreateSheet.swift
//  Tailspot
//
//  Create a challenge (spec §4.1): a prefilled name, Starts now or Schedule,
//  one of four durations, a computed end line, Create. Utility chrome: a
//  branded inset-grouped List inside its own NavigationStack, like Settings.
//  The creator is the first participant; on success the caller receives
//  the detail so it can push it and put the share sheet up.
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
    @State private var error: ChallengesError?

    static let nameMin = 3
    static let nameMax = 24
    static let minLead: TimeInterval = 15 * 60
    static let maxLead: TimeInterval = 14 * 86_400

    /// `_debugName` / `_debugStartMode` seed the snapshot harness.
    init(onCreated: @escaping (ChallengeDetail) -> Void,
         _debugName: String? = nil,
         _debugStartMode: StartMode = .now,
         _debugNow: Date = Date()) {
        self.onCreated = onCreated
        _name = State(initialValue: _debugName ?? ChallengeCopy.suggestedName(for: _debugNow))
        _startMode = State(initialValue: _debugStartMode)
        // Default schedule: the next whole hour at least 15 minutes out.
        let next = Self.nextWholeHour(after: _debugNow.addingTimeInterval(Self.minLead))
        _scheduledAt = State(initialValue: next)
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
        let lead = scheduledAt.timeIntervalSince(model.now())
        return lead >= Self.minLead && lead <= Self.maxLead
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
            VStack(alignment: .leading, spacing: 6) {
                TextField("Weekend Flyoff", text: $name)
                    .font(Brand.Font.body)
                    .foregroundStyle(Brand.Color.textPrimary)
                    .textInputAutocapitalization(.words)
                    .accessibilityLabel("Challenge name")
                HStack {
                    if !trimmedName.isEmpty && !nameValid {
                        Text(trimmedName.count < Self.nameMin ? "At least \(Self.nameMin) characters." : "At most \(Self.nameMax) characters.")
                            .font(Brand.Font.caption)
                            .foregroundStyle(Brand.Color.alertCaution)
                    }
                    Spacer()
                    Text("\(trimmedName.count)/\(Self.nameMax)")
                        .font(Brand.Font.mono(size: 10, relativeTo: .caption2))
                        .foregroundStyle(Brand.Color.textTertiary)
                        .monospacedDigit()
                }
            }
        } header: {
            header("NAME")
        }
        .listRowBackground(Brand.Color.bgElevated)
    }

    private var startSection: some View {
        Section {
            Picker("Start", selection: $startMode) {
                ForEach(StartMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Start")
            if startMode == .scheduled {
                DatePicker("Starts",
                           selection: $scheduledAt,
                           in: model.now().addingTimeInterval(Self.minLead)...model.now().addingTimeInterval(Self.maxLead),
                           displayedComponents: [.date, .hourAndMinute])
                    .font(Brand.Font.body)
                    .foregroundStyle(Brand.Color.textPrimary)
                    .tint(Brand.Color.cyan)
                if !scheduleValid {
                    Text("Pick a start between 15 minutes and 14 days from now.")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.alertCaution)
                }
            }
        } header: {
            header("START")
        }
        .listRowBackground(Brand.Color.bgElevated)
    }

    private var durationSection: some View {
        Section {
            GlassSegmentedSlider(
                selection: $duration,
                segments: Duration.allCases,
                segmentHeight: 40,
                trackPadding: 4,
                accessibilityTitle: "Duration",
                segmentTitle: { $0.label }
            ) { d, isSelected in
                Text(d.short)
                    .font(Brand.Font.mono(size: 12, weight: isSelected ? .bold : .regular, relativeTo: .caption))
                    .tracking(0.8)
                    .foregroundStyle(isSelected ? Brand.Color.bgPrimary : Brand.Color.textSecondary)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .listRowBackground(Color.clear)
            Text("\(duration.label) · \(ChallengeCopy.endsLine(endsAt: endsAt, now: model.now()))")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textSecondary)
                .listRowBackground(Brand.Color.bgElevated)
        } header: {
            header("DURATION")
        }
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
        } footer: {
            Text("You're in as soon as you create it. Share the link with up to nine others; anyone can join until it ends.")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textTertiary)
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
