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
    /// A shorter keep-for choice that would delete conversations already
    /// saved, waiting for a yes.
    @State private var pendingRetention: HistoryRetention?
    @State private var deleteError: String?
    /// A conversation swiped away, waiting for a yes: a slip while
    /// scrolling shouldn't delete a named or starred one for good.
    @State private var pendingDeletion: TranscriptSessionSummary?
    /// "What did I talk about with Ronit": a name that was never said aloud
    /// can't be found by the free-text search, so filtering by who was
    /// there is a separate, composable way in.
    @State private var speakerFilter: String?

    private var savingSection: some View {
        Section {
            if viewModel.saveHistory, viewModel.historySaveFailure != nil {
                Label(tr("השמירה האחרונה של שיחה נכשלה, כנראה כי אין מקום פנוי בטלפון. מה שנאמר מאז אולי לא נשמר.", "The last conversation save failed, probably because the phone is out of space. What was said since then may not have been saved."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Toggle(tr("לשמור שיחות", "Save conversations"), isOn: $viewModel.saveHistory)
            Picker(tr("מחיקה אוטומטית", "Automatic deletion"), selection: retentionChoice) {
                ForEach(HistoryRetention.allCases, id: \.self) { retention in
                    Text(Self.name(for: retention)).tag(retention)
                }
            }
        } footer: {
            Text(savingFooter)
        }
    }

    private var savingFooter: String {
        let size = ModelManagerView.format(bytes: totalSize)
        let base = tr("השיחות נשמרות רק בטלפון הזה (\(size)). הן לא מגובות לשום מקום ואפשר למחוק אותן בכל רגע.", "Conversations are saved only on this phone (\(size)). They aren’t backed up anywhere, and can be deleted anytime.")
        guard viewModel.historyRetention != .forever else { return base }
        return base + tr(" שיחות עם שורה מסומנת או עם שם נשמרות תמיד.", " Conversations with a starred line or a name are always kept.")
    }

    /// A conversation that fell on today's date a year or more ago,
    /// surfaced without her having to remember it happened or scroll back
    /// to find it.
    private var onThisDaySection: some View {
        let now = Date().timeIntervalSince1970
        let matches = Array(OnThisDay.matches(in: sessions, now: now, utcOffsetSeconds: HistoryDays.localOffset).prefix(3))
        return Group {
            if !matches.isEmpty {
                Section {
                    ForEach(matches) { session in
                        sessionLink(session)
                    }
                } header: {
                    Text(tr("לפני שנה בתאריך הזה", "On this day"))
                }
            }
        }
    }

    private var starredSection: some View {
        Section {
            NavigationLink {
                StarredLinesView(viewModel: viewModel, onHistoryChanged: reload)
            } label: {
                Label(tr("השורות המסומנות", "Starred lines"), systemImage: "star.fill")
                    .badge(sessions.reduce(0) { $0 + $1.starredCount })
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("starredLinesRow")
        }
    }

    /// Under "today", "yesterday", a weekday or a date: "what the doctor
    /// said on Tuesday" is found by the day, not by reading every date.
    @ViewBuilder
    private var conversationsSection: some View {
        if filteredSessions.isEmpty {
            Section {
                Text(emptyConversationsMessage)
                    .foregroundStyle(.secondary)
            } header: {
                Text(tr("שיחות", "Conversations"))
            }
        }
        ForEach(sessionDays) { day in
            Section {
                ForEach(day.sessions) { session in
                    sessionLink(session)
                }
            } header: {
                Text(day.title)
            }
        }
    }

    private var emptyConversationsMessage: String {
        if !query.isEmpty { return tr("לא נמצא כלום עבור \"\(query)\".", "Nothing found for “\(query)”.") }
        if let speakerFilter { return tr("אין שיחות עם \(speakerFilter).", "No conversations with \(speakerFilter).") }
        return tr("עדיין אין שיחות שמורות.", "No saved conversations yet.")
    }

    /// Tapping a name above filters to conversations with that person in
    /// them, composing with a text search already in progress.
    private var filteredSessions: [TranscriptSessionSummary] {
        guard let speakerFilter else { return sessions }
        return sessions.filter { $0.speakerNames.contains(speakerFilter) }
    }

    private var topSpeakers: [String] {
        TranscriptSessionSummary.topSpeakerNames(in: sessions)
    }

    @ViewBuilder
    private var speakerFilterSection: some View {
        if !topSpeakers.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(topSpeakers, id: \.self) { name in
                            speakerChip(name)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
        }
    }

    private func speakerChip(_ name: String) -> some View {
        let isSelected = speakerFilter == name
        return Button {
            speakerFilter = isSelected ? nil : name
        } label: {
            Text(name)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var sessionDays: [HistoryDay] {
        HistoryDays.grouped(filteredSessions, now: Date().timeIntervalSince1970, utcOffsetSeconds: HistoryDays.localOffset)
    }

    private func sessionLink(_ session: TranscriptSessionSummary) -> some View {
        NavigationLink {
            HistoryDetailView(viewModel: viewModel, sessionID: session.id, searchQuery: query, onHistoryChanged: reload)
        } label: {
            SessionRow(session: session)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // No destructive role: that role animates the row away
            // before the question is even answered.
            Button {
                pendingDeletion = session
            } label: {
                Label(tr("מחיקה", "Delete"), systemImage: "trash")
            }
            .tint(.red)
        }
    }

    private func delete(_ session: TranscriptSessionSummary) {
        do {
            try viewModel.deleteConversation(id: session.id)
        } catch {
            deleteError = error.localizedDescription
        }
        reload()
    }

    var body: some View {
        List {
            if query.isEmpty {
                savingSection
            }
            if query.isEmpty, sessions.contains(where: { $0.starredCount > 0 }) {
                starredSection
            }
            if query.isEmpty {
                onThisDaySection
                speakerFilterSection
            }
            conversationsSection
        }
        .accessibilityIdentifier("historyScreen")
        .searchable(text: $query, prompt: tr("חיפוש במה שנאמר", "Search what was said"))
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
        .navigationTitle(tr("היסטוריה", "History"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    confirmingDeleteAll = true
                } label: {
                    Label(tr("מחיקת הכול", "Delete all"), systemImage: "trash")
                }
                .disabled(sessions.isEmpty)
            }
        }
        .confirmationDialog(
            Self.expiryWarning(count: pendingRetention.map { expiredCount(under: $0) } ?? 0),
            isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } }),
            titleVisibility: .visible
        ) {
            Button(tr("למחוק ולהמשיך כך", "Delete and continue this way"), role: .destructive) {
                if let retention = pendingRetention {
                    apply(retention)
                }
            }
            Button(tr("ביטול", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("שיחות עם שורה מסומנת או עם שם לא יימחקו.", "Conversations with a starred line or a name won’t be deleted."))
        }
        .alert(tr("המחיקה נכשלה", "Deletion failed"), isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button(tr("סגור", "Close"), role: .cancel) {}
        } message: {
            Text(tr("מה שלא נמחק עדיין שמור בטלפון. אפשר לנסות שוב.\n\(deleteError ?? "")", "What wasn’t deleted is still saved on the phone. You can try again.\n\(deleteError ?? "")"))
        }
        .confirmationDialog(
            tr("למחוק את השיחה הזו?", "Delete this conversation?"),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { session in
            Button(tr("מחיקה", "Delete"), role: .destructive) {
                delete(session)
            }
            Button(tr("ביטול", "Cancel"), role: .cancel) {}
        } message: { session in
            Text(session.title ?? CaptionLayout.directed(session.preview))
        }
        .confirmationDialog(tr("למחוק את כל השיחות השמורות?", "Delete all saved conversations?"), isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
            Button(tr("מחיקת הכול", "Delete all"), role: .destructive) {
                do {
                    try viewModel.deleteAllConversations()
                } catch {
                    deleteError = error.localizedDescription
                }
                reload()
            }
            Button(tr("ביטול", "Cancel"), role: .cancel) {}
        }
    }

    /// Picking a shorter time asks first when it would delete something
    /// right away; anything else just takes effect.
    private var retentionChoice: Binding<HistoryRetention> {
        Binding(
            get: { viewModel.historyRetention },
            set: { choice in
                if expiredCount(under: choice) > 0 {
                    pendingRetention = choice
                } else {
                    apply(choice)
                }
            }
        )
    }

    private func expiredCount(under retention: HistoryRetention) -> Int {
        guard let cutoff = retention.cutoff(now: Date().timeIntervalSince1970) else { return 0 }
        return sessions.filter { $0.lastActiveAt < cutoff && !$0.isKeptByChoice }.count
    }

    private func apply(_ retention: HistoryRetention) {
        viewModel.historyRetention = retention
        Task {
            await viewModel.deleteExpiredHistory()
            await reloadInBackground()
        }
    }

    static func expiryWarning(count: Int) -> String {
        switch count {
        case 1: return tr("שיחה ישנה אחת תימחק עכשיו", "1 old conversation will be deleted now")
        case 2: return tr("שתי שיחות ישנות יימחקו עכשיו", "2 old conversations will be deleted now")
        default: return tr("\(count) שיחות ישנות יימחקו עכשיו", "\(count) old conversations will be deleted now")
        }
    }

    static func name(for retention: HistoryRetention) -> String {
        switch retention {
        case .forever: return tr("אף פעם", "Never")
        case .year: return tr("אחרי שנה", "After a year")
        case .threeMonths: return tr("אחרי 3 חודשים", "After 3 months")
        case .month: return tr("אחרי חודש", "After a month")
        case .week: return tr("אחרי שבוע", "After a week")
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let session: TranscriptSessionSummary

    // A long conversation's duration reads as a phrase ("3 שעות ו-27
    // דקות" — "3 hours and 27 minutes"), not just a number, so at the
    // largest accessibility text size it can wrap; a plain HStack then let
    // it interleave with the time on the opposite side instead of sitting
    // below it.
    private var timeLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = session.title {
                Text(title)
                    .font(.headline)
            }
            timeLayout {
                Text(Date(timeIntervalSince1970: session.startedAt).formatted(date: .omitted, time: .shortened))
                    .font(session.title == nil ? .subheadline.weight(.semibold) : .subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let duration = session.durationSeconds {
                    Text(ConversationStats.minutesText(duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if !session.speakerNames.isEmpty {
                Label(session.speakerNames.prefix(3).joined(separator: ", ") + (session.speakerNames.count > 3 ? tr(" ועוד", " and more") : ""), systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(CaptionLayout.directed(session.preview))
                .font(.body)
                .lineLimit(2)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(ConversationStats.linesText(session.segmentCount))
                if session.starredCount > 0 {
                    Label("\(session.starredCount)", systemImage: "star.fill")
                        .foregroundStyle(Color.yellow.readable(on: colorScheme))
                        .accessibilityLabel(ConversationStats.linesText(session.starredCount, adjective: (singular: "מסומנת", plural: "מסומנות"), englishAdjective: "starred"))
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}
