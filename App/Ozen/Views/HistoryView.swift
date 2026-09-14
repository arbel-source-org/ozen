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

            if query.isEmpty, sessions.contains(where: { $0.starredCount > 0 }) {
                Section {
                    NavigationLink {
                        StarredLinesView(viewModel: viewModel, onDelete: reload)
                    } label: {
                        Label("השורות המסומנות", systemImage: "star.fill")
                            .badge(sessions.reduce(0) { $0 + $1.starredCount })
                    }
                }
            }

            Section {
                if sessions.isEmpty {
                    Text(query.isEmpty ? "עדיין אין שיחות שמורות." : "לא נמצא כלום עבור \"\(query)\".")
                        .foregroundStyle(.secondary)
                }
                ForEach(sessions) { session in
                    NavigationLink {
                        HistoryDetailView(viewModel: viewModel, sessionID: session.id, searchQuery: query, onDelete: reload)
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
            HStack(spacing: 10) {
                Text("\(session.segmentCount) שורות")
                if session.starredCount > 0 {
                    Label("\(session.starredCount)", systemImage: "star.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("\(session.starredCount) שורות מסומנות")
                }
            }
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
    /// The search that led here, if any: its lines are highlighted and
    /// the first one is scrolled into view.
    var searchQuery: String = ""
    /// A line to open at, when arriving from the starred lines list.
    var initialLineID: UUID?
    let onDelete: () -> Void
    @State private var record: TranscriptSessionRecord?
    @State private var stats: ConversationStats?
    @State private var matches: [UUID] = []
    @State private var currentMatch = 0
    @State private var hasJumped = false
    @State private var scrollRequest = 0
    @State private var hasLoaded = false
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    private var isSearch: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if !hasLoaded {
                ProgressView()
            } else if let record {
                ScrollViewReader { proxy in
                List {
                    if let stats, stats.totalWords > 0 {
                        ConversationSummarySection(stats: stats)
                    }
                    Section {
                        ForEach(Array(record.segments.enumerated()), id: \.element.id) { index, segment in
                            VStack(alignment: .leading, spacing: 2) {
                                if let name = segment.speakerName,
                                   CaptionLayout.showsSpeakerLabel(for: segment, after: index > 0 ? record.segments[index - 1] : nil) {
                                    Text(name)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(SpeakerColor.color(forClusterID: segment.speakerClusterID))
                                }
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    if segment.isStarred {
                                        Image(systemName: "star.fill")
                                            .foregroundStyle(.yellow)
                                    }
                                    Text(CaptionLayout.readableText(segment.text))
                                        .font(.system(size: max(17, viewModel.display.fontSize * 0.7)))
                                }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel((segment.isStarred ? "מסומן כחשוב. " : "") + (segment.speakerName.map { "\($0): \(segment.text)" } ?? segment.text))
                            .accessibilityHint(isSearch && matches.contains(segment.id) ? "מכיל את מה שחיפשת" : "")
                            .listRowBackground(isSearch && matches.contains(segment.id) ? Color.yellow.opacity(0.3) : nil)
                            .id(segment.id)
                        }
                    } header: {
                        Text(Date(timeIntervalSince1970: record.startedAt).formatted(date: .long, time: .shortened))
                    } footer: {
                        Text("\(record.engine.displayName)\(record.modelVariant.map { " · \($0)" } ?? "")\(record.inputName.map { " · \($0)" } ?? "")")
                    }
                }
                .task {
                    // Give the list a moment to lay out, then open where the
                    // search found something instead of at the top.
                    guard let target = isSearch ? matches.first : initialLineID else { return }
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                }
                .onChange(of: scrollRequest) { _, _ in
                    guard matches.indices.contains(currentMatch) else { return }
                    withAnimation { proxy.scrollTo(matches[currentMatch], anchor: .center) }
                }
                }
            } else {
                ContentUnavailableView("השיחה לא נמצאה", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle("שיחה")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if matches.count > (isSearch ? 1 : 0) {
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        // Stars start from the first one; a search is
                        // already showing its first match.
                        currentMatch = isSearch || hasJumped ? (currentMatch + 1) % matches.count : 0
                        hasJumped = true
                        scrollRequest += 1
                    } label: {
                        Label(
                            isSearch
                                ? "המקום הבא (\(currentMatch + 1) מתוך \(matches.count))"
                                : (hasJumped ? "הסימון הבא (\(currentMatch + 1) מתוך \(matches.count))" : "לשורות המסומנות (\(matches.count))"),
                            systemImage: isSearch ? "chevron.down" : "star.fill"
                        )
                        .labelStyle(.titleAndIcon)
                    }
                }
            }
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
        .task {
            // Loaded and summarised once, off the main thread: a long
            // conversation's words shouldn't be counted on every redraw, or
            // hold up the screen sliding in.
            guard !hasLoaded else { return }
            let store = viewModel.historyStore
            let id = sessionID
            let query = searchQuery
            let (loaded, summary, found) = await Task.detached(priority: .userInitiated) {
                let loaded = store.load(id: id)
                return (
                    loaded,
                    loaded.map(ConversationStats.compute(from:)),
                    // With no search, the button steps through starred lines.
                    loaded.map { record in
                        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? record.segments.filter(\.isStarred).map(\.id)
                            : TranscriptHistoryStore.matchingSegmentIDs(in: record, query: query)
                    } ?? []
                )
            }.value
            record = loaded
            stats = summary
            matches = found
            hasLoaded = true
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

/// Every starred line from every saved conversation, newest first: the
/// quick way back to "what did the doctor say about the pills".
struct StarredLinesView: View {
    let viewModel: LiveCaptionViewModel
    let onDelete: () -> Void
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
                                    HistoryDetailView(viewModel: viewModel, sessionID: line.sessionID, initialLineID: line.id, onDelete: onDelete)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        if let name = line.segment.speakerName, !TranscriptSessionSummary.isGenericLabel(name) {
                                            Text(name)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(SpeakerColor.color(forClusterID: line.segment.speakerClusterID))
                                        }
                                        Text(CaptionLayout.readableText(line.segment.text))
                                            .font(.system(size: max(17, viewModel.display.fontSize * 0.7)))
                                    }
                                }
                            }
                        } header: {
                            Text(Date(timeIntervalSince1970: group.startedAt).formatted(date: .long, time: .shortened))
                        }
                    }
                }
            }
        }
        .navigationTitle("שורות מסומנות")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let store = viewModel.historyStore
            lines = await Task.detached(priority: .userInitiated) { store.starredLines() }.value
            hasLoaded = true
        }
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
