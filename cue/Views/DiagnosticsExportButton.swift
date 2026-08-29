import SwiftUI
import UIKit

/// The *Export Diagnostics* toolbar item: flush, snapshot, write one file into
/// Documents, hand it to a share sheet.
///
/// Its own file rather than more state on `DownloadsView`, which is already
/// close to the strict 400-line cap, and because the export is a self-contained
/// capability the Downloads screen merely hosts.
struct DiagnosticsExportButton: View {
    @Environment(\.diagnostics) private var diagnostics
    @Environment(\.diagnosticsSnapshots) private var snapshots

    @State private var exported: ExportedDiagnostics?
    @State private var exportErrorMessage: String?

    var body: some View {
        Button {
            Task { await export() }
        } label: {
            Label("Export Diagnostics", systemImage: "square.and.arrow.up")
        }
        .sheet(item: $exported) { file in
            DiagnosticsShareSheet(url: file.url)
        }
        .errorAlert("Could Not Export Diagnostics", $exportErrorMessage)
    }

    private func export() async {
        do {
            let url = try await DiagnosticsExport.export(
                from: snapshots,
                flushing: diagnostics,
                environment: DiagnosticsExport.current,
                timestamp: Date(),
                toDirectory: DiagnosticsExport.defaultDirectory()
            )
            exported = ExportedDiagnostics(url: url)
        } catch {
            exportErrorMessage = diagnosticsExportErrorMessage(for: error)
        }
    }
}

/// `sheet(item:)` needs an identity, and the file's own URL is one: a second
/// export replaces the file at the same path, so presenting it again is the
/// same sheet showing newer bytes.
struct ExportedDiagnostics: Identifiable {
    let url: URL
    var id: URL { url }
}

/// SwiftUI has no share sheet that takes a file URL and stays a toolbar item,
/// so this is the one UIKit representable in the tree.
struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
