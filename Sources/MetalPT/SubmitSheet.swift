import AppKit
import MPTApp
import MPTCore
import SwiftUI

/// "Submit…" (spec §4.A.4, `runs-submit.html` right side): exactly what the upload holds, the graphics settings
/// (required to publish; missing ones highlighted), the video link, the "Also send my notes" tick, "Export file…"
/// (writes `<exports>/<run>.mptrun.zip` and shows it in Finder) and Publish → "Published" with Open page / Copy link,
/// or the site's message.
struct SubmitSheet: View {
    enum Phase: Equatable {
        case editing
        case publishing
        case published(SiteClient.Published)
        case failed(String)
    }

    let entry: RunEntry
    @ObservedObject var store: RunsStore
    /// Where "Export file…" writes (the data root's `exports`).
    let exportsFolder: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var previews: (withoutNotes: ExportPreview, withNotes: ExportPreview)?
    @State private var includeNotes: Bool
    @State private var exporting = false
    @State private var exported: URL?
    @State private var problem: String?
    @State private var graphics: GraphicsDraft
    @State private var video: String
    @State private var phase: Phase
    /// Publish was pressed with fields missing (they are highlighted from then on, or from the start in snapshots).
    @State private var showMissing: Bool
    @Environment(\.openURL) private var openURL
    @Environment(\.rendersSnapshot) private var snapshot

    /// `previews` given (snapshots): shown as is, nothing read. `phase` (snapshots) sets the publish state; else a
    /// published run opens as published.
    init(entry: RunEntry, store: RunsStore, exportsFolder: URL,
         previews: (withoutNotes: ExportPreview, withNotes: ExportPreview)? = nil, includeNotes: Bool = false,
         videoURL: String? = nil, phase: Phase? = nil, showMissing: Bool = false) {
        self.entry = entry
        self.store = store
        self.exportsFolder = exportsFolder
        _previews = State(initialValue: previews)
        _includeNotes = State(initialValue: includeNotes)
        _graphics = State(initialValue: GraphicsDraft(entry.graphics))
        _video = State(initialValue: videoURL ?? "")
        let published = entry.publishedID.flatMap { id in
            entry.publishedURL.map { SiteClient.Published(id: id, url: $0) }
        }
        _phase = State(initialValue: phase ?? published.map { .published($0) } ?? .editing)
        _showMissing = State(initialValue: showMissing)
    }

    private var preview: ExportPreview? { previews.map { includeNotes ? $0.withNotes : $0.withoutNotes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Publish this run").font(.title3.weight(.semibold))
                Text(isPublished ? "This run is on metal-pt.com."
                                 : "This is exactly what will be sent to metal-pt.com. Nothing leaves your Mac until "
                                   + "you press Publish.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if let preview {
                    details(preview)
                } else if problem == nil {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            if case .published = phase {} else {
                GraphicsFields(draft: $graphics, highlight: highlighted, title: "Graphics (needed to publish)",
                               footnote: "What you set in the game; saved with the run.")
                    .disabled(phase == .publishing)
                videoField
                if let preview {
                    notesTick(preview)
                }
            }
            if let note = store.siteKeyNote {
                Label(note, systemImage: "key.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            statusArea
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let exported {
                Label("Saved \(exported.lastPathComponent) in \(exported.deletingLastPathComponent().path)",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export file…") { export() }
                    .disabled(preview == nil || exporting || tooLarge)
                    .help("Save the upload file (one .mptrun.zip) to \(exportsFolder.path) and show it in Finder")
                if case .published = phase {} else {
                    Button(isFailed ? "Try Again" : "Publish") { publish() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(preview == nil || tooLarge || phase == .publishing || videoProblem != nil
                                  || graphics.customProblem)
                        .help("Send this run to metal-pt.com (\(SiteClient.defaultBase.host ?? "metal-pt.com"))")
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            guard previews == nil else { return }
            do {
                previews = try await store.exportPreviews(entry.id)
            } catch {
                problem = "Could not read this run: \(error.localizedDescription)"
            }
        }
        .task {
            // The run's stored link (the index does not hold it); snapshots pass theirs.
            guard video.isEmpty, previews == nil, let f = try? await store.userFields(entry.id) else { return }
            video = f.videoURL ?? ""
        }
        .onChange(of: includeNotes) { exported = nil }
    }

    private var isPublished: Bool { if case .published = phase { true } else { false } }

    private var isFailed: Bool { if case .failed = phase { true } else { false } }

    private var highlighted: Set<GraphicsDraft.Field> { showMissing ? Set(graphics.missing) : [] }

    private var videoProblem: String? {
        let t = video.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || YouTubeLink.videoID(from: t) != nil ? nil : "Only YouTube links (youtube.com, youtu.be)"
    }

    private var videoField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("YouTube video about this run").font(.subheadline.weight(.semibold))
            SnapshotSafeTextField("https://www.youtube.com/watch?v=…", text: $video)
                .disabled(phase == .publishing)
            if let videoProblem {
                Label(videoProblem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("Optional. Only YouTube links; shown on the run's page.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        switch phase {
        case .editing:
            if showMissing, !graphics.missing.isEmpty {
                Label("Set \(graphics.missing.map(\.rawValue).joined(separator: ", ")) to publish.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        case .publishing:
            HStack(spacing: 8) {
                if snapshot {
                    // `ProgressView` does not render in `ImageRenderer`.
                    Image(systemName: "arrow.up.circle").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("Publishing to metal-pt.com…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .published(let p):
            publishedPanel(p)
        }
    }

    private func publishedPanel(_ p: SiteClient.Published) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(p.alreadyPublished ? "Already published" : "Published", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(scheme == .dark ? Color(nsColor: .systemGreen) : Color(red: 0.11, green: 0.48, blue: 0.24))
            Text(p.url.absoluteString)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            if let notice = p.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Open Page") { openURL(p.url) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(p.url.absoluteString, forType: .string)
                }
                Spacer()
                Text("Remove it from the run's menu in Runs.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.green.opacity(0.35)))
    }

    private func publish() {
        guard graphics.missing.isEmpty, let g = graphics.graphics else {
            showMissing = true
            return
        }
        phase = .publishing
        let include = includeNotes
        let v = video.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let p = try await store.publish(entry.id, includeNotes: include, graphics: g,
                                                videoURL: v.isEmpty ? nil : v)
                phase = .published(p)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private var tooLarge: Bool { (preview?.bytes ?? 0) > RunExport.maxBytes }

    private func details(_ p: ExportPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Game", p.game)
            if let app = p.recordedApp { row("Recorded app", app) }
            row("Stack", p.stackLine ?? "not detected", dim: p.stackLine == nil)
            row("Mac", p.mac)
            row("Conditions", p.conditions)
            row("Settings you typed", p.settings.isEmpty ? "none" : "“\(p.settings)”", dim: p.settings.isEmpty)
            if !p.label.isEmpty { row("Label", "“\(p.label)”") }
            if let notes = p.notes {
                row("Notes", "“\(notes)”")
            } else {
                row("Notes", p.hasNotes ? "not sent" : "none", dim: true)
            }
            if !p.warnings.isEmpty { row("Warnings", p.warnings.joined(separator: "\n")) }
            row("Data", dataText(p))
            Label(p.privacyLine, systemImage: "checkmark")
                .foregroundStyle(scheme == .dark ? Color(nsColor: .systemGreen)
                                                 : Color(red: 0.11, green: 0.48, blue: 0.24))
            if tooLarge {
                Label(RunExport.Error.tooLarge(bytes: p.bytes).localizedDescription,
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    }

    /// "120 s of 1 Hz samples (31 columns), 7,012 frame times · 412 KB"
    private func dataText(_ p: ExportPreview) -> String {
        let frames = p.frameCount.map { "\($0.formatted()) frame times" } ?? "no frame times"
        return "\(p.sampleCount.formatted()) s of 1 Hz samples (\(p.columnCount) columns), \(frames) · "
            + RunExport.sizeText(p.bytes)
    }

    private func row(_ title: String, _ value: String, dim: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).fontWeight(.semibold).frame(width: 128, alignment: .leading)
            Text(value)
                .foregroundStyle(dim ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// A drawn tick box (an AppKit `Toggle` does not render in snapshots).
    private func notesTick(_ p: ExportPreview) -> some View {
        Button { includeNotes.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: includeNotes ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(includeNotes ? Color.accentColor : .secondary)
                Text("Also send my notes (free text you typed)")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!p.hasNotes)
        .opacity(p.hasNotes ? 1 : 0.45)
        .help(p.hasNotes ? "Notes stay on this Mac unless ticked" : "This run has no notes")
    }

    private func export() {
        exporting = true
        problem = nil
        exported = nil
        let include = includeNotes
        Task {
            do {
                let url = try await store.export(entry.id, includeNotes: include, to: exportsFolder)
                exported = url
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                problem = "Could not export: \(error.localizedDescription)"
            }
            exporting = false
        }
    }
}
