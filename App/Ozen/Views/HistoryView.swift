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
                        StarredLinesView(viewModel: viewModel, onHistoryChanged: reload)
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
                        HistoryDetailView(viewModel: viewModel, sessionID: session.id, searchQuery: query, onHistoryChanged: reload)
                    } label: {
                        SessionRow(session: session)
                    }
                }
                .onDelete { offsets in
                    for offset in offsets {
                        try? viewModel.deleteConversation(id: sessions[offset].id)
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
                try? viewModel.deleteAllConversations()
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
            if let title = session.title {
                Text(title)
                    .font(.headline)
            }
            HStack {
                Text(Date(timeIntervalSince1970: session.startedAt).formatted(date: .abbreviated, time: .shortened))
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
