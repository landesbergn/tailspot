//
//  HandleClaimCard.swift
//  Tailspot
//
//  The inline "pick a handle first" card the Challenges create and join
//  sheets show when the device has no claimed handle (spec §4.1 step 1 and
//  §4.3 step 3). One component, two call sites. The validation and the
//  claim round-trip live in HandleClaimer, shared with HandleEditSheet.
//

import SwiftUI

struct HandleClaimCard: View {
    /// Analytics source for `handle_claimed` ("challenge_join", "challenge_create").
    let source: String
    let onClaimed: () -> Void

    @State private var draft = ""
    @State private var error: String?
    @State private var isClaiming = false
    private let claimer = HandleClaimer()

    init(source: String, onClaimed: @escaping () -> Void) {
        self.source = source
        self.onClaimed = onClaimed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick a handle first")
                .font(Brand.Font.cardTitle)
                .foregroundStyle(Brand.Color.textPrimary)
            Text("It's what the other spotters see. Letters, numbers and underscores, 3 to 20 characters.")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textSecondary)
            HStack(spacing: 6) {
                Text("@").foregroundStyle(Brand.Color.textTertiary)
                TextField("handle", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Brand.Font.mono(size: 17, relativeTo: .body))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .accessibilityLabel("Handle")
                    .onChange(of: draft) { _, _ in error = nil }
                    .onSubmit { Task { await claim() } }
                if isClaiming { ProgressView().scaleEffect(0.75).tint(Brand.Color.cyan) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Brand.Color.bgPrimary.opacity(0.6), in: .rect(cornerRadius: Brand.Radius.row))
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.alertCaution)
            }
            Button { Task { await claim() } } label: {
                Text("Claim handle")
                    .font(Brand.Font.mono(size: 13, weight: .bold, relativeTo: .footnote))
                    .foregroundStyle(isValid ? Brand.Color.cyan : Brand.Color.textTertiary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isValid || isClaiming)
        }
        .padding(16)
        .background(Brand.Color.bgElevated.opacity(0.75), in: .rect(cornerRadius: Brand.Radius.card))
    }

    private var isValid: Bool { HandleRules.isValid(draft) }

    private func claim() async {
        guard isValid else { return }
        isClaiming = true
        defer { isClaiming = false }
        let result = await claimer.claim(draft, source: source)
        if case .saved = result {
            error = nil
            onClaimed()
        } else {
            error = result.message
        }
    }
}
