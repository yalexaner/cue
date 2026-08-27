import SwiftData
import SwiftUI
import UIKit

/// The add-feed sheet: paste a feed address, subscribe to it (spec §6).
///
/// The address is sent to `FeedService` as typed apart from surrounding
/// whitespace, which is a paste artifact rather than part of the URL — tokens
/// and query strings are never rewritten (spec §6).
///
/// Failures stay inline instead of becoming an alert: the field that produced
/// the error is still on screen and still editable, so the fix is one edit away.
struct AddFeedView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.diagnostics) private var diagnostics
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var addTask: Task<Void, Never>?
    @State private var pasteDetection: FeedPasteDetection = .unavailable
    @FocusState private var isFieldFocused: Bool

    private var trimmedURLString: String {
        normalisedFeedAddress(urlString)
    }

    private var offersPaste: Bool {
        shouldOfferFeedPaste(detection: pasteDetection, fieldText: urlString)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Feed address", text: $urlString)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .focused($isFieldFocused)
                            .disabled(isAdding)
                            .onSubmit(submit)
                        if !urlString.isEmpty && !isAdding {
                            Button {
                                urlString = ""
                                isFieldFocused = true
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear feed address")
                        }
                    }
                    if offersPaste {
                        // reading the clipboard is what may prompt, so it happens
                        // on this tap and never on appear (decision 15)
                        Button("Paste from Clipboard", systemImage: "doc.on.clipboard", action: paste)
                            .disabled(isAdding)
                    }
                } header: {
                    Text("Feed address")
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    } else {
                        Text("The address of the podcast's RSS feed, for example https://example.com/feed.xml")
                    }
                }
            }
            .navigationTitle("Add Feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // stays live while a fetch is outstanding: a host that
                    // black-holes the connection holds the request for the
                    // whole `URLSession` timeout, and this is the only way out
                    Button("Cancel") {
                        addTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isAdding {
                        ProgressView()
                    } else {
                        Button("Add", action: submit)
                            .disabled(trimmedURLString.isEmpty)
                    }
                }
            }
            // a stray swipe would dismiss the sheet mid-fetch and land the
            // failure message on a view nobody can see, leaving the feed
            // silently unadded — leaving is Cancel's job, which says so
            .interactiveDismissDisabled(isAdding)
            .task {
                isFieldFocused = true
                await detectClipboard()
            }
        }
    }

    private func submit() {
        guard !isAdding, !trimmedURLString.isEmpty else { return }
        addTask = Task { await add() }
    }

    /// Asks only what shape the clipboard holds. This call does not prompt, and
    /// a failure means no offer rather than a blind read.
    private func detectClipboard() async {
        let webURL = \UIPasteboard.DetectedValues.probableWebURL
        guard let patterns = try? await UIPasteboard.general.detectedPatterns(for: [webURL]) else {
            pasteDetection = .unavailable
            return
        }
        pasteDetection = .detected(containsProbableWebURL: patterns.contains(webURL))
    }

    private func paste() {
        // revalidated rather than trusted: the clipboard can change between
        // detection and this read
        guard let pasted = pastedFeedAddress(fromClipboard: UIPasteboard.general.string) else { return }
        urlString = pasted
        errorMessage = nil
    }

    private func add() async {
        isAdding = true
        errorMessage = nil
        defer { isAdding = false }

        do {
            try await FeedService(context: context, diagnostics: diagnostics)
                .add(urlString: trimmedURLString)
            dismiss()
        } catch {
            // nil when Cancel got here first: the sheet is already dismissed and
            // there is nothing to report
            errorMessage = reportableFeedErrorMessage(for: error, host: DiagnosticsHost(trimmedURLString))
        }
    }
}
