import SwiftUI
import UIKit
import OzenKit

/// Every starred line from every saved conversation, newest first: the
/// quick way back to "what did the doctor say about the pills".
struct StarredLinesView: View {
    @Environment(\.colorScheme) private var colorScheme
    let viewModel: LiveCaptionViewModel
    /// Something in saved history changed here (a deletion, a new name).
    let onHistoryChanged: () -> Void
    @State private var lines: [StarredLine] = []
    @State private var hasLoaded = false

    var body: some View {
        Group {
            if !hasLoaded {
                ProgressView()
            } else if lines.isEmpty {
                ContentUnavailableView("אין שורות מסומנות", systemImage: "star", description: Text("לחיצה ארוכה על שורה בזמן השיחה מסמנת אותה כחשובה."))
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.lines) { line in
                                NavigationLink {
                                    HistoryDetailView(viewModel: viewModel, sessionID: line.sessionID, initialLineID: line.id) {
                                        // Deleted from inside: both lists drop it.
                                        Task { await load() }
                                        onHistoryChanged()
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(Date(timeIntervalSince1970: line.segment.startTimestamp).formatted(date: .omitted, time: .shortened))
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                            if let name = line.segment.speakerName, !TranscriptSessionSummary.isGenericLabel(name) {
                                                Text(name)
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(SpeakerColor.color(forClusterID: line.segment.speakerClusterID, on: colorScheme))
                                            }
                                        }
                                        Text(
                                            caption: CaptionLayout.displayText(line.segment.text),
                                            emphasizingNumbers: viewModel.display.emphasizeNumbers,
                                            size: max(17, viewModel.display.fontSize * 0.7),
                                            numberColor: nil
                                        )
                                            .font(.system(size: max(17, viewModel.display.fontSize * 0.7)))
                                    }
                                }
                                .contextMenu {
                                    Button {
                                        UIPasteboard.general.string = line.segment.text
                                    } label: {
                                        Label("העתקה", systemImage: "doc.on.doc")
                                    }
                                }
                            }
                        } header: {
                            Text(Self.heading(startedAt: group.startedAt))
                        }
                    }
                }
            }
        }
        .navigationTitle("שורות מסומנות")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !lines.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(
                        item: TranscriptHistoryStore.exportStarredText(lines, utcOffsetSeconds: TimeZone.current.secondsFromGMT()),
                        subject: Text("שורות מסומנות מאוזן")
                    ) {
                        Label("שיתוף", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task { await load() }
    }

    /// "Yesterday at 18:30", like the day headings in History.
    static func heading(startedAt: TimeInterval) -> String {
        let day = HistoryDays.title(of: startedAt, now: Date().timeIntervalSince1970) {
            TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: $0))
        }
        return "\(day) בשעה \(Date(timeIntervalSince1970: startedAt).formatted(date: .omitted, time: .shortened))"
    }

    private func load() async {
        let store = viewModel.historyStore
        lines = await Task.detached(priority: .userInitiated) { store.starredLines() }.value
        hasLoaded = true
    }

    private struct ConversationStars: Identifiable {
        let sessionID: UUID
        let startedAt: TimeInterval
        var lines: [StarredLine]
        var id: UUID { sessionID }
    }

    private var groups: [ConversationStars] {
        var result: [ConversationStars] = []
        for line in lines {
            if let last = result.indices.last, result[last].sessionID == line.sessionID {
                result[last].lines.append(line)
            } else {
                result.append(ConversationStars(sessionID: line.sessionID, startedAt: line.sessionStartedAt, lines: [line]))
            }
        }
        return result
    }
}
