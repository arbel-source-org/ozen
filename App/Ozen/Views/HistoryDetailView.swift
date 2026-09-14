import SwiftUI
import UIKit
import OzenKit

struct HistoryDetailView: View {
    let viewModel: LiveCaptionViewModel
    let sessionID: UUID
    /// The search that led here, if any: its lines are highlighted and
    /// the first one is scrolled into view.
    var searchQuery: String = ""
    /// A line to open at, when arriving from the starred lines list.
    var initialLineID: UUID?
    /// Something in saved history changed here (a deletion, a new name).
    let onHistoryChanged: () -> Void
    @State private var record: TranscriptSessionRecord?
    @State private var stats: ConversationStats?
    @State private var matches: [UUID] = []
    @State private var timeMarks: Set<UUID> = []
    /// Lines with a time, an amount or a phone number in them, in order.
    @State private var numberLineIDs: [UUID] = []
    @State private var currentMatch = 0
    @State private var hasJumped = false
    @State private var scrollRequest = 0
    @State private var hasLoaded = false
    @State private var confirmingDelete = false
    @State private var deleteError: String?
    @State private var renaming = false
    @State private var newTitle = ""
    @Environment(\.dismiss) private var dismiss

    private var isSearch: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let listedNumberLines = 12

    /// "What time was the appointment again?": every line with a number in
    /// it, gathered at the top, each one a tap away from where it was said.
    private func numbersSection(_ record: TranscriptSessionRecord, proxy: ScrollViewProxy) -> some View {
        let wanted = Set(numberLineIDs.prefix(Self.listedNumberLines))
        let lines = record.segments.filter { wanted.contains($0.id) }
        return Section {
            // Numbered rather than by line: the transcript below already
            // uses the line IDs, and a second view with the same ID would
            // be the one a tap scrolls to.
            ForEach(Array(lines.enumerated()), id: \.offset) { _, segment in
                Button {
                    withAnimation { proxy.scrollTo(segment.id, anchor: .center) }
                } label: {
                    NumberLineLabel(segment: segment)
                }
                .accessibilityHint("מעבר לשורה בשיחה")
                .contextMenu { copyButton(segment.text) }
                .accessibilityActions { copyButton(segment.text) }
            }
            if numberLineIDs.count > Self.listedNumberLines {
                Text("ועוד \(ConversationStats.linesText(numberLineIDs.count - Self.listedNumberLines)) עם מספרים בהמשך השיחה")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("מספרים שנאמרו")
        } footer: {
            Text("שעות, כמויות ומספרי טלפון מהשיחה. נגיעה בשורה מובילה אליה.")
        }
    }

    private func transcriptList(_ record: TranscriptSessionRecord) -> some View {
        ScrollViewReader { proxy in
            List {
                if let stats, stats.totalWords > 0 {
                    ConversationSummarySection(stats: stats)
                }
                if !isSearch, !numberLineIDs.isEmpty {
                    numbersSection(record, proxy: proxy)
                }
                Section {
                    ForEach(Array(record.segments.enumerated()), id: \.element.id) { index, segment in
                        let isMatch = isSearch && matches.contains(segment.id)
                        SavedLineRow(
                            segment: segment,
                            previous: index > 0 ? record.segments[index - 1] : nil,
                            showsTime: timeMarks.contains(segment.id),
                            markUncertain: viewModel.display.markUncertainLines,
                            fontSize: viewModel.display.fontSize,
                            emphasizeNumbers: viewModel.display.emphasizeNumbers,
                            isMatch: isMatch
                        )
                        .listRowBackground(isMatch ? Color.yellow.opacity(0.3) : nil)
                        .id(segment.id)
                        .contextMenu { copyButton(segment.text) }
                        .accessibilityActions { copyButton(segment.text) }
                    }
                } header: {
                    Text(Date(timeIntervalSince1970: record.startedAt).formatted(date: .long, time: .shortened))
                } footer: {
                    Text(Self.sourceLine(for: record))
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
    }

    /// A phone number or an address said, to paste somewhere else.
    private func copyButton(_ text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
        } label: {
            Label("העתקה", systemImage: "doc.on.doc")
        }
    }

    private static func sourceLine(for record: TranscriptSessionRecord) -> String {
        [record.engine.displayName, record.modelVariant, record.inputName]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var nextMatchTitle: String {
        if isSearch {
            return "המקום הבא (\(currentMatch + 1) מתוך \(matches.count))"
        }
        return hasJumped
            ? "הסימון הבא (\(currentMatch + 1) מתוך \(matches.count))"
            : "לשורות המסומנות (\(matches.count))"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if matches.count > (isSearch ? 1 : 0) {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    // Stars start from the first one; a search is
                    // already showing its first match.
                    currentMatch = isSearch || hasJumped ? (currentMatch + 1) % matches.count : 0
                    hasJumped = true
                    scrollRequest += 1
                } label: {
                    Label(nextMatchTitle, systemImage: isSearch ? "chevron.down" : "star.fill")
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
                Button {
                    newTitle = record.title ?? ""
                    renaming = true
                } label: {
                    Label("מתן שם לשיחה", systemImage: "pencil")
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

    var body: some View {
        Group {
            if !hasLoaded {
                ProgressView()
            } else if let record {
                transcriptList(record)
            } else {
                ContentUnavailableView("השיחה לא נמצאה", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(record?.title ?? "שיחה")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .alert("שם לשיחה", isPresented: $renaming) {
            TextField("למשל: ביקור אצל הרופא", text: $newTitle)
            Button("שמירה") {
                viewModel.renameConversation(id: sessionID, title: newTitle)
                let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                record?.title = trimmed.isEmpty ? nil : trimmed
                // The list behind this screen shows the name too.
                onHistoryChanged()
            }
            Button("ביטול", role: .cancel) {}
        } message: {
            Text("השם יופיע ברשימת השיחות, ואפשר יהיה לחפש לפיו.")
        }
        .alert("המחיקה נכשלה", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("סגור", role: .cancel) {}
        } message: {
            Text("מה שלא נמחק עדיין שמור בטלפון. אפשר לנסות שוב.\n\(deleteError ?? "")")
        }
        .confirmationDialog("למחוק את השיחה הזו?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("מחיקה", role: .destructive) {
                do {
                    try viewModel.deleteConversation(id: sessionID)
                    onHistoryChanged()
                    dismiss()
                } catch {
                    deleteError = error.localizedDescription
                }
            }
            Button("ביטול", role: .cancel) {}
        }
        .task { await load() }
    }

    /// Everything the screen shows about one saved conversation, worked
    /// out together off the main thread.
    nonisolated private struct Loaded: Sendable {
        let record: TranscriptSessionRecord?
        let stats: ConversationStats?
        let matches: [UUID]
        let timeMarks: Set<UUID>
        let numberLineIDs: [UUID]

        init(store: TranscriptHistoryStore, id: UUID, query: String) {
            let loaded = store.load(id: id)
            record = loaded
            stats = loaded.map(ConversationStats.compute(from:))
            guard let loaded else {
                matches = []
                timeMarks = []
                numberLineIDs = []
                return
            }
            // With no search, the button steps through starred lines.
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                matches = loaded.segments.filter(\.isStarred).map(\.id)
            } else {
                matches = TranscriptHistoryStore.matchingSegmentIDs(in: loaded, query: query)
            }
            timeMarks = CaptionLayout.timeMarkedLineIDs(in: loaded.segments)
            numberLineIDs = loaded.segments.filter { NumberEmphasis.hasListableNumber($0.text) }.map(\.id)
        }
    }

    /// Loaded and summarised once, off the main thread: a long
    /// conversation's words shouldn't be counted on every redraw, or hold
    /// up the screen sliding in.
    private func load() async {
        guard !hasLoaded else { return }
        let store = viewModel.historyStore
        let id = sessionID
        let query = searchQuery
        let loaded = await Task.detached(priority: .userInitiated) {
            Loaded(store: store, id: id, query: query)
        }.value
        record = loaded.record
        stats = loaded.stats
        matches = loaded.matches
        timeMarks = loaded.timeMarks
        numberLineIDs = loaded.numberLineIDs
        // Opened at a starred line: "next" continues from that one.
        if let initialLineID, let index = loaded.matches.firstIndex(of: initialLineID) {
            currentMatch = index
            hasJumped = true
        }
        hasLoaded = true
    }
}

/// One line under "numbers said": who said it, when known, and the line
/// with its numbers standing out. "3 pills" means more with "the doctor" on it.
private struct NumberLineLabel: View {
    let segment: SavedSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let name = segment.speakerName, !TranscriptSessionSummary.isGenericLabel(name) {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(
                caption: CaptionLayout.directed(segment.text),
                emphasizingNumbers: true,
                size: 17,
                numberColor: nil
            )
            .font(.body)
            .foregroundStyle(.primary)
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Who said how much, at the top of a saved conversation.
private struct ConversationSummarySection: View {
    @Environment(\.colorScheme) private var colorScheme
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
                        .tint(SpeakerColor.color(forClusterID: speaker.clusterID, on: colorScheme))
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

/// One saved caption line: the time now and then, the speaker at the start
/// of their turn, a star, and the question mark for an unsure line.
private struct SavedLineRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let segment: SavedSegment
    let previous: SavedSegment?
    let showsTime: Bool
    let markUncertain: Bool
    let fontSize: Double
    let emphasizeNumbers: Bool
    let isMatch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsTime {
                Text(Date(timeIntervalSince1970: segment.startTimestamp).formatted(date: .omitted, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let name = segment.speakerName, CaptionLayout.showsSpeakerLabel(for: segment, after: previous) {
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SpeakerColor.color(forClusterID: segment.speakerClusterID, on: colorScheme))
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if segment.isStarred {
                    Image(systemName: "star.fill")
                        .foregroundStyle(Color.yellow.readable(on: colorScheme))
                }
                if isUncertain {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("ייתכן שלא נשמע נכון")
                }
                Text(
                    caption: CaptionLayout.displayText(segment.text),
                    emphasizingNumbers: emphasizeNumbers,
                    size: max(17, fontSize * 0.7),
                    numberColor: nil
                )
                    .font(.system(size: max(17, fontSize * 0.7)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(isMatch ? "מכילה את מה שחיפשת" : "")
    }

    private var isUncertain: Bool {
        markUncertain && CaptionConfidence.isUncertain(confidence: segment.confidence, isCommitted: segment.isCommitted)
    }

    private var accessibilityText: String {
        let star = segment.isStarred ? "מסומן כחשוב. " : ""
        guard let name = segment.speakerName else { return star + segment.text }
        return star + "\(name): \(segment.text)"
    }
}
