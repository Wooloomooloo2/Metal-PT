import AppKit
import MPTApp
import MPTCore
import SwiftUI

/// "Submit…" (spec §6, `runs-submit.html` right side): exactly what the upload file holds, the "Also send my notes"
/// tick, "Export file…" (writes `<exports>/<run>.mptrun.zip` and shows it in Finder) and Submit, disabled until the
/// website exists.
struct SubmitSheet: View {
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

    /// `previews` given (snapshots): shown as is, nothing read.
    init(entry: RunEntry, store: RunsStore, exportsFolder: URL,
         previews: (withoutNotes: ExportPreview, withNotes: ExportPreview)? = nil, includeNotes: Bool = false) {
        self.entry = entry
        self.store = store
        self.exportsFolder = exportsFolder
        _previews = State(initialValue: previews)
        _includeNotes = State(initialValue: includeNotes)
    }

    private var preview: ExportPreview? { previews.map { includeNotes ? $0.withNotes : $0.withoutNotes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Submit this run").font(.title3.weight(.semibold))
                Text("This is exactly what will be sent. Nothing leaves your Mac until you press Submit.")
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
            if let preview {
                notesTick(preview)
            }
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
                Button("Submit (website coming soon)") {}
                    .disabled(true)
                    .help("Submitting arrives when the Metal-PT website exists. Use Export file… for now.")
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            guard previews == nil else { return }
            do {
                previews = try await store.exportPreviews(entry.id)
            } catch {
                problem = "Could not read this run: \(error.localizedDescription)"
            }
        }
        .onChange(of: includeNotes) { exported = nil }
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
