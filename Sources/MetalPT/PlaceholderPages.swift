import MPTApp
import SwiftUI

/// A page that arrives in a later task: a calm "coming next" view.
struct PlaceholderPage: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.title2.weight(.semibold))
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Text("Coming next")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Live, until the charts arrive (T8): the followed game, Record, warnings, and where the charts will go.
struct LivePlaceholder: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: TelemetryHub

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GameHeader(model: model, hub: hub, large: true)
            ProblemsView(model: model, hub: hub)
            VStack(spacing: 10) {
                ChartSlot(title: "FPS and frame time", detail: "last 5 minutes", height: 150)
                ChartSlot(title: "Power and utilisation", detail: nil, height: 110)
                ChartSlot(title: "Temperatures and fans", detail: nil, height: 90)
            }
            HStack {
                RecordButton(model: model)
                Spacer()
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ChartSlot: View {
    let title: String
    let detail: String?
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.05)))
            .frame(height: height)
            .overlay {
                VStack(spacing: 2) {
                    Text(title).font(.callout.weight(.medium))
                    Text(detail.map { "\($0) · coming next" } ?? "coming next").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
    }
}
