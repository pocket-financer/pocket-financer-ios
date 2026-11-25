import SwiftUI

struct DecisionTraceTimeline: View {
    let events: [SmsProcessingTraceEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if events.isEmpty {
                ContentUnavailableView(
                    "No native decision trace",
                    systemImage: "timeline.selection",
                    description: Text("Legacy processing details remain available below.")
                )
            } else {
                ForEach(events, id: \.id) { event in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon(event.statusRawValue))
                            .foregroundStyle(color(event.statusRawValue))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.stageRawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.headline)
                            Text(event.statusRawValue.capitalized)
                                .font(.caption.weight(.semibold))
                            ForEach(event.reasonCodes, id: \.self) { code in
                                Text(code)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            if let detail = event.detailJSON, !detail.isEmpty {
                                DisclosureGroup("Stored detail") {
                                    Text(detail)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func icon(_ status: String) -> String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "retained": "tray.full.fill"
        case "interrupted": "pause.circle.fill"
        case "running": "hourglass.circle.fill"
        default: "circle"
        }
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "completed": .green
        case "failed": .red
        case "retained": .orange
        default: .secondary
        }
    }
}
