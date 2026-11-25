import AppKit
import MPTApp
import MPTCore
import SwiftUI

/// Runs (spec §5, `runs-submit.html`): the filterable list of recordings on the left, the selected run's summary on
/// the right. Ticked runs → "Compare selected…" makes a compare project and opens Compare.
struct RunsPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: RunsStore
    @State private var filter = ""
    /// The run shown on the right (nil: the first in the list).
    @State private var selection: String?
    /// Runs ticked for comparison.
    @State private var ticked: Set<String>
    @State private var editing: RunEntry?
    @State private var submitting: RunEntry?
    @State private var deleting: RunEntry?
    @State private var problem: String?

    init(model: AppModel, ticked: Set<String> = [], filter: String = "") {
        self.model = model
        self.store = model.runs
        _ticked = State(initialValue: ticked)
        _filter = State(initialValue: filter)
    }

    private var visible: [RunEntry] { store.entries.filter { $0.matches(filter) } }

    private var shown: RunEntry? {
        if let selection, let e = visible.first(where: { $0.id == selection }) { return e }
        return visible.first
    }

    var body: some View {
        Group {
            if store.loaded && store.entries.isEmpty {
                RunsEmptyState(combo: model.recordCombo.display, folder: store.root ?? model.folder("runs"))
            } else {
                HStack(spacing: 0) {
                    listColumn.frame(width: 300)
                    Divider()
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            refresh()
            selectRequestedRun()
        }
        .onChange(of: store.entries) {
            ticked.formIntersection(store.entries.filter { !$0.inProgress }.map(\.id))
            selectRequestedRun()
        }
        .onChange(of: model.selectedRun) { selectRequestedRun() }
        .sheet(item: $editing) { entry in
            EditNotesSheet(entry: entry, store: store)
        }
        .sheet(item: $submitting) { entry in
            SubmitSheet(entry: entry, store: store, exportsFolder: model.folder("exports"))
        }
        .confirmationDialog("Move this run to the Trash?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { entry in
            Button("Move to Trash", role: .destructive) { delete(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("\(entry.game), \(RunFormat.date(entry.start)). The folder \(entry.id) goes to the Trash; "
                 + "you can put it back from there.")
        }
        .alert("Runs", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") {}
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: - List

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    SnapshotSafeTextField("Filter: game, app, stack, settings, label", text: $filter, plain: true)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.secondary).padding(4)
                }
                    .buttonStyle(.plain)
                    .help("Rescan the runs folder")
            }
            .padding(10)
            Divider()
            if visible.isEmpty && store.loaded {
                Text("No runs match “\(filter)”.")
                    .foregroundStyle(.secondary)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                SnapshotSafeScroll {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { entry in
                            row(entry)
                            Divider().padding(.leading, 38)
                        }
                    }
                }
            }
            Divider()
            compareBar
        }
    }

    private func row(_ entry: RunEntry) -> some View {
        RunRow(entry: entry, selected: shown?.id == entry.id, ticked: ticked.contains(entry.id)) {
            if ticked.contains(entry.id) { ticked.remove(entry.id) } else { ticked.insert(entry.id) }
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = entry.id }
        .contextMenu {
            Button("Edit Settings and Notes…") { editing = entry }
                .disabled(entry.inProgress)
            Button("Submit…") { submitting = entry }
                .disabled(entry.inProgress)
            Button("Show in Finder") {
                if let url = store.url(of: entry.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Divider()
            Button("Move to Trash…", role: .destructive) { deleting = entry }
                .disabled(entry.inProgress)
        }
    }

    private var compareBar: some View {
        HStack {
            Button(compareTitle) { compare() }
                .disabled(ticked.count < 2)
            if ticked.count < 2 {
                Text("Tick two or more runs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Clear") { ticked.removeAll() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
            }
            Spacer()
        }
        .padding(10)
    }

    /// "Compare 3 selected…", or "Compare 3 selected (1 hidden)…" when the filter hides some ticked runs (all ticked
    /// runs are compared).
    private var compareTitle: String {
        guard ticked.count >= 2 else { return "Compare selected…" }
        let hidden = ticked.subtracting(visible.map(\.id)).count
        return hidden > 0 ? "Compare \(ticked.count) selected (\(hidden) hidden)…" : "Compare \(ticked.count) selected…"
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let entry = shown {
            RunDetailView(entry: entry, store: store, debug: model.debugLogging, onEdit: { editing = entry },
                          onSubmit: { submitting = entry })
        } else if !store.loaded {
            ProgressView().controlSize(.small)
        } else {
            Text("Select a run to see its summary.").foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func refresh() {
        guard model.live else { return }   // snapshots show a fixed folder
        store.refresh(root: model.folder("runs"))
    }

    /// A "Run saved" notification asked for this run: select it once the index has it (clearing a filter that
    /// would hide it).
    private func selectRequestedRun() {
        guard let url = model.selectedRun else { return }
        let id = url.lastPathComponent
        guard let entry = store.entry(id) else { return }
        if !entry.matches(filter) { filter = "" }
        selection = id
        model.selectedRun = nil
    }

    private func compare() {
        let runs = store.entries.filter { ticked.contains($0.id) && !$0.inProgress }
        do {
            try model.compare(runs)
            ticked.removeAll()
        } catch {
            problem = "Could not create the comparison: \(error.localizedDescription)"
        }
    }

    private func delete(_ entry: RunEntry) {
        Task {
            do {
                try await store.delete(entry.id)
                if selection == entry.id { selection = nil }
            } catch {
                problem = "Could not move the run to the Trash: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Row

private struct RunRow: View {
    let entry: RunEntry
    let selected: Bool
    let ticked: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: toggle) {
                Image(systemName: ticked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(ticked ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(entry.inProgress)
            .opacity(entry.inProgress ? 0.35 : 1)
            .help(entry.inProgress ? "Still recording" : ticked ? "Untick (leave out of the comparison)" : "Tick to compare")
            VStack(alignment: .leading, spacing: 2) {
                // A title the user gave, with the recorded app after it in secondary text.
                (Text(entry.game)
                    + Text(entry.title != nil && !entry.app.isEmpty ? "  \(entry.app)" : "")
                        .font(.subheadline).foregroundStyle(.secondary))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let sub = [entry.stackLine, entry.settings, entry.label].filter { !$0.isEmpty }
                Text(sub.isEmpty ? "Stack unknown" : sub.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if entry.inProgress {
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Text("Recording… · started \(RunFormat.date(entry.start))")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                } else {
                    // One text, so a long line wraps as a sentence rather than squeezing each piece.
                    (Text("\(RunFormat.date(entry.start)) · \(RunFormat.duration(entry.duration)) · ")
                        + Text(RunFormat.fps(entry.medianFPS)).fontWeight(.semibold)
                        + Text(RunFormat.statSuffix(low1: entry.low1, fpsPerWatt: entry.fpsPerWatt)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear)
    }
}

// MARK: - Empty state

private struct RunsEmptyState: View {
    let combo: String
    let folder: URL

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No runs yet — press \(combo) in a game")
                .font(.title2.weight(.semibold))
            Text("Each recording is saved as a run, listed here with its summary. Add the game settings you used "
                 + "after it stops, then compare runs side by side.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Text(Privacy.scrubPaths(folder.path))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Formatting

/// `DateFormatter`s are costly to make and the lists format many dates: one per template, calendar identifier,
/// locale and time zone.
private enum ShortDateFormatters {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

    static func formatter(_ template: String, _ calendar: Calendar) -> DateFormatter {
        let locale = calendar.locale ?? .current
        let key = "\(template)|\(calendar.identifier)|\(locale.identifier)|\(calendar.timeZone.identifier)"
        return lock.withLock {
            if let f = cache[key] { return f }
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = locale
            f.setLocalizedDateFormatFromTemplate(template)
            cache[key] = f
            return f
        }
    }
}

enum RunFormat {
    /// "Today 14:02", "Yesterday 19:40", "22 Nov 19:40" (locale order), with the year when not this year.
    static func date(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return "Today \(time)" }
        if cal.isDateInYesterday(d) { return "Yesterday \(time)" }
        if cal.isDate(d, equalTo: now, toGranularity: .year) {
            return d.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    /// "Today 9:50", "12 Aug" (this year), "12 Aug 2025" (earlier years): compact, for lists of old runs. Time and
    /// day order follow the calendar's locale.
    static func shortDate(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        func string(_ template: String) -> String {
            ShortDateFormatters.formatter(template, calendar).string(from: d)
        }
        if calendar.isDate(d, inSameDayAs: now) { return "Today \(string("jm"))" }
        return calendar.isDate(d, equalTo: now, toGranularity: .year) ? string("dMMM") : string("dMMMy")
    }

    /// "2:00", "1:02:03".
    static func duration(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        let h = t / 3600, m = (t / 60) % 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Median FPS, one decimal; "—" when unknown.
    static func fps(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.1f", v)
    }

    /// FPS per watt, two decimals; nil when unknown (the row leaves it out).
    static func perWatt(_ v: Double?) -> String? {
        guard let v, v.isFinite else { return nil }
        return String(format: "%.2f", v)
    }

    /// " fps · 1% 48 · 1.50 FPS/W", leaving out a part (and its separator) that is unknown.
    static func statSuffix(low1: Double?, fpsPerWatt: Double?) -> String {
        var s = " fps"
        if let v = low1, v.isFinite { s += " \u{00B7} 1% \(low(v))" }
        if let w = perWatt(fpsPerWatt) { s += " \u{00B7} \(w)\u{00A0}FPS/W" }
        return s
    }

    /// 1 % low, whole frames; "—" when unknown.
    static func low(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(Int(v.rounded()))
    }
}

/// `ScrollView` in the app; a plain stack when rendering snapshots (`ImageRenderer` does not draw AppKit-backed
/// scroll views).
struct SnapshotSafeScroll<Content: View>: View {
    @Environment(\.rendersSnapshot) private var snapshot
    @ViewBuilder let content: Content

    var body: some View {
        if snapshot {
            VStack(spacing: 0) { content; Spacer(minLength: 0) }
        } else {
            ScrollView { content }
        }
    }
}

/// A text field; in snapshots, its text (or placeholder) drawn in a field-like box (`ImageRenderer` does not draw
/// AppKit-backed fields).
struct SnapshotSafeTextField: View {
    let placeholder: String
    @Binding var text: String
    var plain = false
    @Environment(\.rendersSnapshot) private var snapshot

    init(_ placeholder: String, text: Binding<String>, plain: Bool = false) {
        self.placeholder = placeholder
        _text = text
        self.plain = plain
    }

    var body: some View {
        if snapshot {
            Text(text.isEmpty ? placeholder : text)
                .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, plain ? 0 : 6)
                .padding(.vertical, plain ? 0 : 4)
                .background {
                    if !plain {
                        RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor))
                        RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.2))
                    }
                }
        } else if plain {
            TextField(placeholder, text: $text).textFieldStyle(.plain)
        } else {
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
        }
    }
}

extension EnvironmentValues {
    /// True while `--render-snapshots` draws a view: AppKit-backed views (web view, scroll view) are drawn as stand-ins.
    @Entry var rendersSnapshot = false
}
