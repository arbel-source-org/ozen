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

    private var savingSection: some View {
        Section {
            if viewModel.saveHistory, viewModel.historySaveFailure != nil {
                Label("השמירה האחרונה של שיחה נכשלה, כנראה כי אין מקום פנוי בטלפון. מה שנאמר מאז אולי לא נשמר.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Toggle("לשמור שיחות", isOn: $viewModel.saveHistory)
            Picker("מחיקה אוטומטית", selection: retentionChoice) {
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
        let base = "השיחות נשמרות רק בטלפון הזה (\(size)). הן לא מגובות לשום מקום ואפשר למחוק אותן בכל רגע."
        guard viewModel.historyRetention != .forever else { return base }
        return base + " שיחות עם שורה מסומנת או עם שם נשמרות תמיד."
    }

    private var starredSection: some View {
        Section {
            NavigationLink {
                StarredLinesView(viewModel: viewModel, onHistoryChanged: reload)
            } label: {
                Label("השורות המסומנות", systemImage: "star.fill")
                    .badge(sessions.reduce(0) { $0 + $1.starredCount })
            }
        }
    }

    /// Under "today", "yesterday", a weekday or a date: "what the doctor
    /// said on Tuesday" is found by the day, not by reading every date.
    @ViewBuilder
    private var conversationsSection: some View {
        if sessions.isEmpty {
            Section {
                Text(query.isEmpty ? "עדיין אין שיחות שמורות." : "לא נמצא כלום עבור \"\(query)\".")
                    .foregroundStyle(.secondary)
            } header: {
                Text("שיחות")
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

    private var sessionDays: [HistoryDay] {
        HistoryDays.grouped(sessions, now: Date().timeIntervalSince1970, utcOffsetSeconds: HistoryDays.localOffset)
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
                Label("מחיקה", systemImage: "trash")
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
            conversationsSection
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
        .confirmationDialog(
            Self.expiryWarning(count: pendingRetention.map { expiredCount(under: $0) } ?? 0),
            isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } }),
            titleVisibility: .visible
        ) {
            Button("למחוק ולהמשיך כך", role: .destructive) {
                if let retention = pendingRetention {
                    apply(retention)
                }
            }
            Button("ביטול", role: .cancel) {}
        } message: {
            Text("שיחות עם שורה מסומנת או עם שם לא יימחקו.")
        }
        .alert("המחיקה נכשלה", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("סגור", role: .cancel) {}
        } message: {
            Text("מה שלא נמחק עדיין שמור בטלפון. אפשר לנסות שוב.\n\(deleteError ?? "")")
        }
        .confirmationDialog(
            "למחוק את השיחה הזו?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { session in
            Button("מחיקה", role: .destructive) {
                delete(session)
            }
            Button("ביטול", role: .cancel) {}
        } message: { session in
            Text(session.title ?? CaptionLayout.directed(session.preview))
        }
        .confirmationDialog("למחוק את כל השיחות השמורות?", isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
            Button("מחיקת הכול", role: .destructive) {
                do {
                    try viewModel.deleteAllConversations()
                } catch {
                    deleteError = error.localizedDescription
                }
                reload()
            }
            Button("ביטול", role: .cancel) {}
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
        case 1: return "שיחה ישנה אחת תימחק עכשיו"
        case 2: return "שתי שיחות ישנות יימחקו עכשיו"
        default: return "\(count) שיחות ישנות יימחקו עכשיו"
        }
    }

    static func name(for retention: HistoryRetention) -> String {
        switch retention {
        case .forever: return "אף פעם"
        case .year: return "אחרי שנה"
        case .threeMonths: return "אחרי 3 חודשים"
        case .month: return "אחרי חודש"
        case .week: return "אחרי שבוע"
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
    let session: TranscriptSessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = session.title {
                Text(title)
                    .font(.headline)
            }
            HStack {
                Text(Date(timeIntervalSince1970: session.startedAt).formatted(date: .omitted, time: .shortened))
                    .font(session.title == nil ? .subheadline.weight(.semibold) : .subheadline)
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
            Text(CaptionLayout.directed(session.preview))
                .font(.body)
                .lineLimit(2)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(ConversationStats.linesText(session.segmentCount))
                if session.starredCount > 0 {
                    Label("\(session.starredCount)", systemImage: "star.fill")
                        .foregroundStyle(Color.yellow.readable(on: colorScheme))
                        .accessibilityLabel(ConversationStats.linesText(session.starredCount, adjective: (singular: "מסומנת", plural: "מסומנות")))
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
