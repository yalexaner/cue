import SwiftData
import SwiftUI

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
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var addTask: Task<Void, Never>?

    private var trimmedURLString: String {
        normalisedFeedAddress(urlString)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/feed.xml", text: $urlString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isAdding)
                } header: {
                    Text("Feed address")
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
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
                        Button("Add") { addTask = Task { await add() } }
                            .disabled(trimmedURLString.isEmpty)
                    }
                }
            }
            // a stray swipe would dismiss the sheet mid-fetch and land the
            // failure message on a view nobody can see, leaving the feed
            // silently unadded — leaving is Cancel's job, which says so
            .interactiveDismissDisabled(isAdding)
        }
    }

    private func add() async {
        isAdding = true
        errorMessage = nil
        defer { isAdding = false }

        do {
            try await FeedService(context: context).add(urlString: trimmedURLString)
            dismiss()
        } catch {
            // nil when Cancel got here first: the sheet is already dismissed and
            // there is nothing to report
            errorMessage = reportableFeedErrorMessage(for: error)
        }
    }
}
