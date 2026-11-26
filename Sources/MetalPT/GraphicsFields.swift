import CoreGraphics
import MPTCore
import SwiftUI

/// The in-game graphics settings being edited (the edit sheet and the Submit sheet): pickers' state, and the
/// `RunInfo.Graphics` it stands for.
struct GraphicsDraft: Equatable {
    var preset: RunInfo.Graphics.Preset?
    /// "WxH" of a listed resolution, `customTag`, or nil (not set).
    var resolution: String?
    var customWidth = ""
    var customHeight = ""
    var upscaler: RunInfo.Graphics.Upscaler?
    var upscalerMode: RunInfo.Graphics.UpscalerMode?
    var frameGeneration: Bool?

    static let customTag = "custom"
    static func tag(_ w: Int, _ h: Int) -> String { "\(w)x\(h)" }

    /// The main display's size first (the usual native resolution), then the common ones, without repeats.
    static let resolutionChoices: [(Int, Int)] = {
        var list: [(Int, Int)] = []
        let id = CGMainDisplayID()
        let w = CGDisplayPixelsWide(id), h = CGDisplayPixelsHigh(id)
        if w > 0, h > 0 { list.append((w, h)) }
        for r in RunInfo.Graphics.commonResolutions where !list.contains(where: { $0 == r }) { list.append(r) }
        return list
    }()

    init(_ g: RunInfo.Graphics?) {
        preset = g?.preset
        upscaler = g?.upscaler
        upscalerMode = g?.upscalerMode
        frameGeneration = g?.frameGeneration
        if let w = g?.width, let h = g?.height {
            let listed = Self.resolutionChoices.contains { $0.0 == w && $0.1 == h }
            resolution = listed ? Self.tag(w, h) : Self.customTag
            if !listed { customWidth = "\(w)"; customHeight = "\(h)" }
        }
    }

    var customProblem: Bool { resolution == Self.customTag && parsedCustom == nil }

    private var parsedCustom: (Int, Int)? {
        guard let w = Int(customWidth.trimmingCharacters(in: .whitespaces)),
              let h = Int(customHeight.trimmingCharacters(in: .whitespaces)),
              (1...16384).contains(w), (1...16384).contains(h) else { return nil }
        return (w, h)
    }

    /// The graphics to save: nil (clear) when nothing is set.
    var graphics: RunInfo.Graphics? {
        var g = RunInfo.Graphics(preset: preset, upscaler: upscaler,
                                 upscalerMode: upscaler == .off ? nil : upscalerMode, frameGeneration: frameGeneration)
        if resolution == Self.customTag {
            if let c = parsedCustom { g.width = c.0; g.height = c.1 }
        } else if let r = Self.resolutionChoices.first(where: { Self.tag($0.0, $0.1) == resolution }) {
            g.width = r.0; g.height = r.1
        }
        return g == RunInfo.Graphics() ? nil : g
    }

    enum Field: String, CaseIterable { case preset = "Preset", resolution = "Resolution", upscaler = "Upscaler",
                                            mode = "Mode", frameGeneration = "Frame generation" }

    /// What the website still needs (spec §4.A.4): every field, a mode only when an upscaler is on.
    var missing: [Field] {
        let g = graphics
        var out: [Field] = []
        if g?.preset == nil { out.append(.preset) }
        if g?.width == nil || g?.height == nil { out.append(.resolution) }
        if g?.upscaler == nil { out.append(.upscaler) }
        if let u = g?.upscaler, u != .off, g?.upscalerMode == nil { out.append(.mode) }
        if g?.frameGeneration == nil { out.append(.frameGeneration) }
        return out
    }
}

/// Preset, resolution, upscaler (+ mode) and frame generation pickers. `highlight`: fields drawn as missing.
struct GraphicsFields: View {
    @Binding var draft: GraphicsDraft
    var highlight: Set<GraphicsDraft.Field> = []
    var title = "Graphics"
    var footnote = "What you set in the game. Resolution is the game's render size."

    var body: some View {
        let sizes = GraphicsDraft.resolutionChoices.map { (Optional(GraphicsDraft.tag($0.0, $0.1)), "\($0.0)×\($0.1)") }
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            HStack(alignment: .top, spacing: 12) {
                labelled(.preset) {
                    ChoiceMenu(selection: $draft.preset, missing: highlight.contains(.preset),
                               options: RunInfo.Graphics.Preset.allCases.map { (Optional($0), $0.displayName) })
                }
                labelled(.resolution) {
                    ChoiceMenu(selection: $draft.resolution, missing: highlight.contains(.resolution),
                               options: sizes + [(GraphicsDraft.customTag, "Custom…")])
                }
            }
            if draft.resolution == GraphicsDraft.customTag {
                HStack(spacing: 6) {
                    SnapshotSafeTextField("Width", text: $draft.customWidth).frame(width: 90)
                    Text("×")
                    SnapshotSafeTextField("Height", text: $draft.customHeight).frame(width: 90)
                    if draft.customProblem {
                        Text("Whole pixels, e.g. 2560 × 1440").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                labelled(.upscaler) {
                    ChoiceMenu(selection: $draft.upscaler, missing: highlight.contains(.upscaler),
                               options: RunInfo.Graphics.Upscaler.allCases.map { (Optional($0), $0.displayName) })
                }
                if draft.upscaler != .off {
                    labelled(.mode) {
                        ChoiceMenu(selection: $draft.upscalerMode, missing: highlight.contains(.mode),
                                   options: RunInfo.Graphics.UpscalerMode.allCases.map { (Optional($0), $0.displayName) })
                    }
                }
                labelled(.frameGeneration) {
                    ChoiceMenu(selection: $draft.frameGeneration, missing: highlight.contains(.frameGeneration),
                               options: [(true, "On"), (false, "Off")])
                }
            }
            Text(footnote).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func labelled<C: View>(_ field: GraphicsDraft.Field, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.rawValue).font(.caption)
                .foregroundStyle(highlight.contains(field) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A pick-one menu with a "Not set" entry; in snapshots (a `Menu` does not render in `ImageRenderer`) the choice
/// drawn in a field-like box. `missing`: an orange outline.
struct ChoiceMenu<T: Hashable>: View {
    @Binding var selection: T?
    var missing = false
    let options: [(T?, String)]
    @Environment(\.rendersSnapshot) private var snapshot

    private var current: String { options.first { $0.0 == selection }?.1 ?? "Not set" }

    var body: some View {
        if snapshot {
            HStack {
                Text(current).foregroundStyle(selection == nil ? .tertiary : .primary).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor))
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(missing ? Color.orange : Color.primary.opacity(0.2), lineWidth: missing ? 1.5 : 1)
            }
        } else {
            Picker("", selection: $selection) {
                Text("Not set").tag(T?.none)
                ForEach(options.indices, id: \.self) { i in
                    if let v = options[i].0 { Text(options[i].1).tag(Optional(v)) }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .overlay {
                if missing {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange, lineWidth: 1.5).allowsHitTesting(false)
                }
            }
        }
    }
}
