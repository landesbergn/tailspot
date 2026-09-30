//
//  HandleEditSheet.swift
//  Tailspot
//
//  Change (or first pick) your handle. Opened by tapping the handle on the
//  Profile header and by the Handle row in Settings, so there is one editor
//  and one set of errors. Design agreed 2026-09-30 (option A of the
//  "Handle Editing on Profile" mock): half-height sheet, field prefilled,
//  keyboard up, Save in the top bar, a note that the old handle frees up.
//  No confirm step and no suggestions on "taken" (Noah's calls).
//
//  SwiftUI note: `.presentationDetents([.medium])` is what makes a sheet
//  stop at half height instead of covering the screen; `@FocusState` +
//  setting it in `.task` is how you raise the keyboard on open.
//

import SwiftUI

struct HandleEditSheet: View {
    /// Analytics source for `handle_claimed` ("profile" or "settings").
    let source: String
    /// Called with the saved handle after a successful save, before dismissing.
    var onSaved: (String) -> Void
    /// Test seam: snapshot and unit harnesses inject a fake claimer.
    var claimer: HandleClaimer

    /// The handle as it was when the sheet opened. Frozen on purpose: a save
    /// writes the new handle before the sheet finishes dismissing, and reading
    /// it live made the title and note flip to the "after" state mid-close.
    @State private var handle: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var outcome: HandleClaimOutcome?
    @State private var isSaving = false
    @FocusState private var fieldFocused: Bool

    /// `initialDraft` / `initialOutcome` exist for the snapshot harness, which
    /// can't type or tap; production callers pass only `source` and `onSaved`.
    init(source: String,
         onSaved: @escaping (String) -> Void = { _ in },
         claimer: HandleClaimer? = nil,
         initialDraft: String = "",
         initialOutcome: HandleClaimOutcome? = nil) {
        self.source = source
        self.onSaved = onSaved
        let claimer = claimer ?? HandleClaimer()
        self.claimer = claimer
        _handle = State(initialValue: claimer.defaults.string(forKey: SpotterHandle.storageKey)
                        ?? SpotterHandle.defaultPlaceholder)
        _draft = State(initialValue: initialDraft)
        _outcome = State(initialValue: initialOutcome)
    }

    /// Whether the user already has a real handle (change) or not (claim).
    private var isClaimed: Bool {
        AnalyticsIdentity.isClaimedHandle(handle, placeholder: SpotterHandle.defaultPlaceholder)
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Save turns on only for a valid handle that differs from the current one.
    /// A case-only change ("Noah" → "noah") counts: the server allows it.
    var canSave: Bool {
        HandleEditSheet.canSave(draft: draft, current: isClaimed ? handle : nil) && !isSaving
    }

    static func canSave(draft: String, current: String?) -> Bool {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return HandleRules.isValid(t) && t != current
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 4) {
                    Text("@").foregroundStyle(Brand.Color.textTertiary)
                    TextField("handle", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($fieldFocused)
                        .foregroundStyle(Brand.Color.textPrimary)
                        .accessibilityLabel("Handle")
                        .onChange(of: draft) { _, _ in outcome = nil }
                        .onSubmit { if canSave { Task { await save() } } }
                    if isSaving {
                        ProgressView().scaleEffect(0.8).tint(Brand.Color.cyan)
                    }
                }
                .font(Brand.Font.mono(size: 17, relativeTo: .body))
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Brand.Color.bgPrimary, in: .rect(cornerRadius: Brand.Radius.row))

                if let message = outcome?.message {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.alertCaution)
                } else {
                    Text(isClaimed
                         ? "Letters, numbers and underscores, 3 to 20 characters."
                         : "It's what other spotters see. Letters, numbers and underscores, 3 to 20 characters.")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                }

                if isClaimed {
                    let old = Text(verbatim: "@\(handle)").foregroundStyle(Brand.Color.textPrimary).bold()
                    Text("Your new handle shows everywhere right away, including challenges you've played. \(old) becomes free for anyone to claim.")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Brand.Color.cyan.opacity(0.07), in: .rect(cornerRadius: Brand.Radius.row))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Brand.Color.bgElevated.ignoresSafeArea())
            .navigationTitle(isClaimed ? "Your handle" : "Pick a handle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Disabled mid-save: the request can't be recalled, so
                    // closing here would still rename behind the user's back.
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isClaimed ? "Save" : "Claim") { Task { await save() } }
                        .buttonStyle(.glassProminent)
                        .tint(Brand.Color.cyan)
                        .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isSaving)
        .presentationDragIndicator(.visible)
        .task {
            // Prefill only a real handle; the "spotter_42" placeholder would
            // read as "your handle is spotter_42".
            if draft.isEmpty && isClaimed { draft = handle }
            fieldFocused = true
        }
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }
        let result = await claimer.claim(trimmed, source: source)
        if case .saved(let saved) = result {
            onSaved(saved)
            dismiss()
        } else {
            outcome = result
        }
    }
}

#Preview {
    Color.black.sheet(isPresented: .constant(true)) {
        HandleEditSheet(source: "preview")
    }
}
