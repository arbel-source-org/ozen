import SwiftUI
import OzenKit

/// The reader's own list of words worth a buzz: her name, the
/// grandchildren, "תרופה", "אמבולנס". Matching understands Hebrew's
/// attached prefixes, so "לסבתא" and "וסבתא" both count as "סבתא".
struct KeywordAlertsView: View {
    @Bindable var viewModel: LiveCaptionViewModel
    @State private var newPhrase = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("מילה או שם, למשל: סבתא", text: $newPhrase)
                        .focused($isEditing)
                        .submitLabel(.done)
                        .onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .disabled(newPhrase.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("הוספה")
                }
            } footer: {
                Text("כשמילה מהרשימה נאמרת, הטלפון ירטוט והשורה תודגש בצהוב. גם צורות כמו \"לסבתא\" או \"וסבתא\" נחשבות.")
            }

            Section("הרשימה") {
                if viewModel.keywordAlerts.isEmpty {
                    Text("עדיין אין מילים. הוסיפו את השם שלכם, שמות של נכדים, או מילים כמו \"תרופה\".")
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.keywordAlerts) { alert in
                    Toggle(isOn: Binding(
                        get: { alert.isEnabled },
                        set: { viewModel.setKeywordAlert(id: alert.id, enabled: $0) }
                    )) {
                        Text(alert.phrase)
                            .foregroundStyle(alert.isEnabled ? .primary : .secondary)
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { viewModel.keywordAlerts[$0].id }
                    for id in ids {
                        viewModel.removeKeywordAlert(id: id)
                    }
                }
            }

            if !viewModel.keywordHits.isEmpty {
                Section("נשמעו לאחרונה") {
                    ForEach(viewModel.keywordHits.suffix(10).reversed()) { hit in
                        HStack {
                            Text(hit.match.matchedText)
                            Spacer()
                            Text(Date(timeIntervalSince1970: hit.timestamp).formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .navigationTitle("מילים חשובות")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        viewModel.addKeywordAlert(phrase: newPhrase)
        newPhrase = ""
        isEditing = true
    }
}
