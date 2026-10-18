import SwiftUI

/// Newest-first table of activity entries for the Activity Log window.
public struct ActivityLogView: View {
    private var log: ActivityLog
    private let emptyDescription: String

    public init(log: ActivityLog, emptyDescription: String) {
        self.log = log
        self.emptyDescription = emptyDescription
    }

    private var rows: [ActivityLogEntry] {
        log.entries.reversed()
    }

    public var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text(emptyDescription)
                )
            } else {
                Table(rows) {
                    TableColumn("Time") { entry in
                        Text(entry.date, format: .dateTime.hour().minute().second())
                    }
                    .width(90)
                    TableColumn("Source") { entry in
                        Text(entry.category)
                            .foregroundStyle(.secondary)
                    }
                    .width(70)
                    TableColumn("Operation") { entry in
                        Text(entry.operation)
                            .font(.body.monospaced())
                    }
                    .width(80)
                    TableColumn("Detail") { entry in
                        Text(entry.detail)
                            .font(.body.monospaced())
                            .help(entry.detail)
                    }
                    TableColumn("Status") { entry in
                        if let status = entry.status {
                            Text("\(status)")
                                .foregroundStyle(entry.isFailure ? .red : .primary)
                        }
                    }
                    .width(50)
                    TableColumn("Duration") { entry in
                        if let duration = entry.duration {
                            Text(String(format: "%.2fs", duration))
                        }
                    }
                    .width(70)
                    TableColumn("Note") { entry in
                        Text(entry.note ?? "")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .toolbar {
            Button("Clear", systemImage: "trash") {
                log.clear()
            }
            .help("Clear the activity log")
            .disabled(rows.isEmpty)
        }
    }
}
