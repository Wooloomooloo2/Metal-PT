import AppKit
import MPTApp
import MPTCore
import SwiftUI
import WebKit

/// The selected run: its name, Edit / Submit (`SubmitSheet`), and its summary.html (the same report the CLI writes) in a web view.
struct RunDetailView: View {
    let entry: RunEntry
    @ObservedObject var store: RunsStore
    /// `MPT_DEBUG=1`: log web view loads.
    var debug = false
    let onEdit: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.game)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !entry.stackLine.isEmpty {
                        Text(entry.stackLine).foregroundStyle(.secondary).lineLimit(1)
                    }
                    let sub = [entry.settings, entry.label, RunFormat.date(entry.start)].filter { !$0.isEmpty }
                    Text(sub.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                HStack {
                    Button("Edit Settings/Notes…", action: onEdit)
                        .disabled(entry.inProgress)
                    Button("Submit…", action: onSubmit)
                        .disabled(entry.inProgress)
                        .help(entry.inProgress ? "Still recording: submit once the recording has stopped"
                                               : "See exactly what would be sent, and export the upload file")
                }
                .fixedSize()
            }
            Group {
                if entry.inProgress {
                    // No summary of half a run: it would stay behind as summary.html.
                    VStack(spacing: 8) {
                        Image(systemName: "record.circle").font(.system(size: 30, weight: .light)).foregroundStyle(.red)
                        Text("Recording… The summary appears when the recording stops.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.04))
                } else {
                    SummaryArea(id: entry.id, store: store, debug: debug)
                }
            }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
        }
        .padding(16)
    }
}

/// Loads (writing it first if missing) and shows the run's summary.html; reloads after an edit.
private struct SummaryArea: View {
    let id: String
    @ObservedObject var store: RunsStore
    let debug: Bool
    @Environment(\.rendersSnapshot) private var snapshot
    @State private var result: Result<URL, Error>?

    private var version: Int { store.summaryVersions[id] ?? 0 }

    var body: some View {
        Group {
            if snapshot {
                // Ruling R2: the report itself is reviewed via its own renders.
                ZStack {
                    Color.primary.opacity(0.04)
                    VStack(spacing: 6) {
                        Image(systemName: "doc.richtext").font(.system(size: 30, weight: .light))
                        Text("summary.html — the run's report (tiles, charts, stats), shown in a web view")
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .padding()
                }
            } else {
                switch result {
                case .success(let url):
                    SummaryWebView(file: url, folder: url.deletingLastPathComponent(), version: version, debug: debug)
                case .failure(let error):
                    Text("Could not show this run's summary: \(error.localizedDescription)")
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case nil:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: "\(id)#\(version)") {
            guard !snapshot else { return }
            result = await store.summaryURL(id)
        }
    }
}

/// `WKWebView` on a run's summary.html (or a compare report): JavaScript off (the reports have none), file access
/// limited to `folder` (the run folder; the projects folder), and no navigation anywhere else (links to the web open
/// in the browser).
struct SummaryWebView: NSViewRepresentable {
    let file: URL
    let folder: URL
    /// Bumped when the file is rewritten: reload.
    let version: Int
    var debug = false
    /// For log lines: "summary" (logs the run folder) or "report" (logs the file).
    var kind = "summary"

    func makeCoordinator() -> Coordinator { Coordinator(debug: debug, kind: kind) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let c = context.coordinator
        guard c.file != file || c.version != version else { return }
        c.file = file
        c.folder = folder
        c.version = version
        view.loadFileURL(file, allowingReadAccessTo: folder)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var file: URL?
        var folder: URL?
        var version = -1
        private let debug: Bool
        private let kind: String

        init(debug: Bool, kind: String) { self.debug = debug; self.kind = kind }

        private var loggedName: String {
            (kind == "summary" ? file?.deletingLastPathComponent() : file)?.lastPathComponent ?? "?"
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if url.isFileURL, let folder,
               url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") {
                decisionHandler(.allow)
                return
            }
            if url.scheme == "about" { decisionHandler(.allow); return }
            if action.navigationType == .linkActivated, let scheme = url.scheme, ["http", "https"].contains(scheme) {
                NSWorkspace.shared.open(url)
            }
            if debug { log("blocked navigation to \(url.absoluteString)") }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if debug { log("\(kind) loaded \(loggedName) (v\(version))") }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            // Cancelled by our own policy (a blocked link) is not a failure worth reporting.
            let e = error as NSError
            // 102: "Frame load interrupted", what a cancelled policy decision reports.
            if e.code == NSURLErrorCancelled || (e.domain == "WebKitErrorDomain" && e.code == 102) {
                if debug { log("\(kind) navigation stopped: \(error.localizedDescription)") }
                return
            }
            log("\(kind) failed to load: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log("\(kind) failed to load: \(error.localizedDescription)")
        }

        private func log(_ text: String) {
            try? FileHandle.standardError.write(contentsOf: Data("Metal-PT: \(text)\n".utf8))
        }
    }
}
