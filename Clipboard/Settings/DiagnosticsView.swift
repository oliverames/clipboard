//
//  DiagnosticsView.swift
//  Clipboard
//
//  A read-out of the capture ledger: the miss rate and the event counts behind it,
//  a switch to turn recording on or off, and the most recent events. It shows no
//  clipboard contents — only change counts, event kinds and times — because the
//  ledger never records contents (see CaptureLedger).
//

import SwiftUI
import ClipboardKit

struct DiagnosticsView: View
{
    @AppStorage("captureDiagnosticsEnabled", store: UserDefaults.shared) private var isEnabled = false

    @State private var stats = CaptureStats()
    @State private var recent: [CaptureLedgerEntry] = []

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View
    {
        Form {
            Section {
                LabeledContent("Miss rate", value: self.missRateText)
                LabeledContent("Capture rate", value: self.captureRateText)
            } header: {
                Text("Capture")
            } footer: {
                Text("The miss rate is the share of clipboard changes the app saw that never produced a saved clipping. It needs the capture ledger turned on, and is most meaningful on a device.")
            }

            Section("Change counts") {
                LabeledContent("Seen", value: "\(self.stats.changeCountsSeen)")
                LabeledContent("Saved", value: "\(self.stats.changeCountsSaved)")
            }

            Section("Events") {
                LabeledContent("Changes heard", value: "\(self.stats.changesHeard)")
                LabeledContent("Reloads requested", value: "\(self.stats.reloadsRequested)")
                LabeledContent("Widget runs", value: "\(self.stats.widgetRuns)")
                LabeledContent("Saves", value: "\(self.stats.saves)")
                LabeledContent("Duplicates", value: "\(self.stats.duplicates)")
                LabeledContent("Store waits", value: "\(self.stats.storeWaits)")
                LabeledContent("Store unavailable", value: "\(self.stats.storeUnavailables)")
                LabeledContent("Misses", value: "\(self.stats.misses)")
            }

            Section {
                Toggle("Record capture diagnostics", isOn: self.$isEnabled)
            } footer: {
                Text("Keeps a small, content-free log in the shared container. On by default in development builds.")
            }

            Section {
                Button("Refresh", action: self.reload)
                Button("Clear log", role: .destructive) {
                    CaptureLedger.shared.clear()
                    self.reload()
                }
            }

            if !self.recent.isEmpty
            {
                Section("Recent events") {
                    ForEach(Array(self.recent.enumerated()), id: \.offset) { _, entry in
                        HStack {
                            Text(entry.event.rawValue)
                            Spacer()
                            if let changeCount = entry.changeCount
                            {
                                Text("#\(changeCount)")
                                    .foregroundStyle(.secondary)
                            }
                            Text(Self.timeFormatter.string(from: entry.date))
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .onAppear(perform: self.reload)
    }

    private var missRateText: String
    {
        guard let missRate = self.stats.missRate else { return "—" }
        return missRate.formatted(.percent.precision(.fractionLength(0)))
    }

    private var captureRateText: String
    {
        guard let captureRate = self.stats.captureRate else { return "—" }
        return captureRate.formatted(.percent.precision(.fractionLength(0)))
    }

    private func reload()
    {
        DispatchQueue.global(qos: .userInitiated).async {
            let stats = CaptureLedger.shared.loadStats()
            let recent = CaptureLedger.shared.recentEntries(limit: 150)
            DispatchQueue.main.async {
                self.stats = stats
                self.recent = recent
            }
        }
    }
}
