import SwiftUI
import OzenKit

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
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(newPhrase.trimmingCharacters(in: .whitespaces).isEmpty || typedWordIsOn)
                    .accessibilityLabel(Text(listed == nil ? "הוספה" : "הפעלה"))
                }
                if let listed {
                    Text(listed.isEnabled ? "\"\(listed.phrase)\" כבר ברשימה." : "\"\(listed.phrase)\" כבר ברשימה, במצב כבוי. הקישו על הפלוס כדי להפעיל מחדש.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("כשמילה מהרשימה נאמרת, הטלפון ירטוט והשורה תודגש בצהוב עם פעמון. גם צורות כמו \"לסבתא\" או \"וסבתא\" נחשבות. כדאי לכתוב מילים בלי ה׳ בהתחלה: \"רופא\" ולא \"הרופא\", כדי שגם \"לרופא\" ייחשב.")
            }

            Section("הרשימה") {
                if viewModel.keywordAlerts.isEmpty {
                    Text("עדיין אין מילים. הוסיפו את השם שלך, שמות של נכדים, או מילים כמו \"תרופה\".")
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
                ForEach(unusedSuggestions, id: \.self) { word in
                    Button {
                        viewModel.addKeywordAlert(phrase: word)
                    } label: {
                        Label("להוסיף: \(word)", systemImage: "plus.circle")
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

    private static let suggestions = ["סבתא", "אמא", "תרופה", "רופא"]

    private var listed: KeywordAlert? {
        viewModel.listedKeywordAlert(matching: newPhrase)
    }

    private var typedWordIsOn: Bool {
        listed?.isEnabled == true
    }

    private var unusedSuggestions: [String] {
        Self.suggestions.filter { word in !viewModel.keywordAlerts.contains { HebrewText.normalize($0.phrase) == HebrewText.normalize(word) } }
    }

    private func add() {
        guard !typedWordIsOn else { return }
        viewModel.addKeywordAlert(phrase: newPhrase)
        newPhrase = ""
        isEditing = true
    }
}
