import SwiftUI
import OzenKit

/// Past conversations: searchable list, full read-back, share as text,
/// delete. Everything stays on the phone.
struct HistoryView: View {
    @Bindable var viewModel: LiveCaptionViewModel
    @State private var query = ""
    @State private var sessions: [TranscriptSessionSummary] = []
    @State private var totalSize: Int64 = 0
    @State private var confirmingDeleteAll = false

    var body: some View {
        List {
            Section {
                Toggle("לשמור שיחות", isOn: $viewModel.saveHistory)
            } footer: {
                Text("השיחות נשמרות רק בטלפון הזה (\(ModelManagerView.format(bytes: totalSize))). הן לא מגובות לשום מקום ואפשר למחוק אותן בכל רגע.")
            }

            Section {
                if sessions.isEmpty {
                    Text(query.isEmpty ? "עדיין אין שיחות שמורות." : "לא נמצא כלום עבור \"\(query)\".")
                        .foregroundStyle(.secondary)
                }
                ForEach(sessions) { session in
                    NavigationLink {
                        HistoryDetailView(viewModel: viewModel, sessionID: session.id, onDelete: reload)
                    } label: {
                        SessionRow(session: session)
                    }
                }
                .onDelete { offsets in
                    for offset in offsets {
                        try? viewModel.historyStore.delete(id: sessions[offset].id)
                    }
                    reload()
                }
            } header: {
                Text("שיחות")
            }
        }
        .searchable(text: $query, prompt: "חיפוש במה שנאמר")
        .task(id: query) {
            // Every search reads every saved conversation from disk. Wait
            // for a pause in typing, then do it off the main thread, so a
            // year of history doesn't freeze the keyboard.
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            await reloadInBackground()
        }
        .navigationTitle("היסטוריה")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    confirmingDeleteAll = true
                } label: {
                    Label("מחיקת הכול", systemImage: "trash")
                }
                .disabled(sessions.isEmpty)
            }
        }
        .confirmationDialog("למחוק את כל השיחות השמורות?", isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
            Button("מחיקת הכול", role: .destructive) {
                try? viewModel.historyStore.deleteAll()
                reload()
            }
            Button("ביטול", role: .cancel) {}
        }
    }

    private func reload() {
        Task { await reloadInBackground() }
    }

    private func reloadInBackground() async {
        let store = viewModel.historyStore
        let text = query
        let (found, size) = await Task.detached(priority: .userInitiated) {
            (text.isEmpty ? store.listSummaries() : store.search(text), store.totalSizeOnDisk())
        }.value
        // A newer search may have finished first; only the current one wins.
        guard text == query else { return }
        sessions = found
        totalSize = size
    }
}

private struct SessionRow: View {
    let session: TranscriptSessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Date(timeIntervalSince1970: session.startedAt).formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let duration = session.durationSeconds {
                    Text(Self.durationLabel(duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if !session.speakerNames.isEmpty {
                Label(session.speakerNames.prefix(3).joined(separator: ", ") + (session.speakerNames.count > 3 ? " ועוד" : ""), systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(session.preview)
                .font(.body)
                .lineLimit(2)
                .foregroundStyle(.secondary)
            Text("\(session.segmentCount) שורות")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    static func durationLabel(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "פחות מדקה" }
        if minutes < 60 { return "\(minutes) דק׳" }
        return "\(minutes / 60) שע׳ \(minutes % 60) דק׳"
    }
}

struct HistoryDetailView: View {
    let viewModel: LiveCaptionViewModel
    let sessionID: UUID
    let onDelete: () -> Void
    @State private var record: TranscriptSessionRecord?
    @State private var stats: ConversationStats?
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let record {
                List {
                    if let stats, stats.totalWords > 0 {
                        ConversationSummarySection(stats: stats)
                    }
                    Section {
                        ForEach(record.segments) { segment in
                            VStack(alignment: .leading, spacing: 2) {
                                if let name = segment.speakerName {
                                    Text(name)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(SpeakerColor.color(forClusterID: segment.speakerClusterID))
                                }
                                Text(CaptionLayout.readableText(segment.text))
                                    .font(.system(size: max(17, viewModel.display.fontSize * 0.7)))
                            }
                        }
                    } header: {
                        Text(Date(timeIntervalSince1970: record.startedAt).formatted(date: .long, time: .shortened))
                    } footer: {
                        Text("\(record.engine.displayName)\(record.modelVariant.map { " · \($0)" } ?? "")\(record.inputName.map { " · \($0)" } ?? "")")
                    }
                }
            } else {
                ContentUnavailableView("השיחה לא נמצאה", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle("שיחה")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let record {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(
                        item: TranscriptHistoryStore.exportText(record, utcOffsetSeconds: TimeZone.current.secondsFromGMT()),
                        subject: Text("שיחה מאוזן"),
                        message: Text(Date(timeIntervalSince1970: record.startedAt).formatted(date: .abbreviated, time: .shortened))
                    ) {
                        Label("שיתוף", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("מחיקה", systemImage: "trash")
                    }
                }
            }
        }
        .confirmationDialog("למחוק את השיחה הזו?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("מחיקה", role: .destructive) {
                try? viewModel.historyStore.delete(id: sessionID)
                onDelete()
                dismiss()
            }
            Button("ביטול", role: .cancel) {}
        }
        .onAppear {
            // Loaded and summarised once; a long conversation's word count
            // shouldn't be redone on every redraw.
            let loaded = viewModel.historyStore.load(id: sessionID)
            record = loaded
            stats = loaded.map(ConversationStats.compute(from:))
        }
    }
}

/// Who said how much, at the top of a saved conversation.
private struct ConversationSummarySection: View {
    let stats: ConversationStats

    var body: some View {
        Section {
            Text(stats.hebrewSummary)
                .font(.headline)

            ForEach(stats.speakers) { speaker in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(speaker.name)
                            .fontWeight(.semibold)
                        Spacer()
                        Text("\(ConversationStats.wordsText(speaker.words)) · \(Int((stats.wordFraction(of: speaker) * 100).rounded()))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ProgressView(value: stats.wordFraction(of: speaker))
                        .tint(SpeakerColor.color(forClusterID: speaker.clusterID))
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }

            if stats.wordsPerMinute > 0 {
                LabeledContent("קצב דיבור", value: "\(Int(stats.wordsPerMinute.rounded())) מילים לדקה")
            }
            LabeledContent("חילופי דוברים", value: "\(stats.totalTurns)")
            if let longest = stats.longestTurn, stats.speakers.count > 1 {
                LabeledContent("הדיבור הארוך ביותר", value: "\(longest.speakerName) · \(ConversationStats.wordsText(longest.words))")
            }
        } header: {
            Text("סיכום")
        }
    }
}
