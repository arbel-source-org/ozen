import SwiftUI
import OzenKit

struct KeywordAlertsView: View {
    @Bindable var viewModel: LiveCaptionViewModel
    @State private var newPhrase = ""
    @FocusState private var isEditing: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // The matched phrase has no length limit of its own, so at the largest
    // accessibility text size it can wrap onto a second line; a plain
    // HStack then lets the timestamp interleave with that wrapped line
    // instead of sitting below it (the same overlap shape as the model
    // manager's rating dots).
    private var recentHitLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout())
    }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField(tr("מילה או שם, למשל: סבתא", "A word or name, e.g., grandma"), text: $newPhrase)
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
                    .accessibilityLabel(Text(listed == nil ? tr("הוספה", "Add") : tr("הפעלה", "Turn on")))
                }
                if let listed {
                    Text(listed.isEnabled ? tr("\"\(listed.phrase)\" כבר ברשימה.", "“\(listed.phrase)” is already in the list.") : tr("\"\(listed.phrase)\" כבר ברשימה, במצב כבוי. הקישו על הפלוס כדי להפעיל מחדש.", "“\(listed.phrase)” is already in the list, turned off. Tap the plus to turn it back on."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(tr("כשמילה מהרשימה נאמרת, הטלפון ירטוט והשורה תודגש בצהוב עם פעמון. גם צורות כמו \"לסבתא\" או \"וסבתא\" נחשבות. כדאי לכתוב מילים בלי ה׳ בהתחלה: \"רופא\" ולא \"הרופא\", כדי שגם \"לרופא\" ייחשב.", "When a word from the list is said, the phone will vibrate and the line will be highlighted in yellow with a bell. Forms like “to grandma” or “and grandma” count too. It’s best to write words without a leading “the”: “doctor” instead of “the doctor”, so “to the doctor” counts too."))
            }

            Section(tr("הרשימה", "List")) {
                if viewModel.keywordAlerts.isEmpty {
                    Text(tr("עדיין אין מילים. הוסיפו את השם שלך, שמות של נכדים, או מילים כמו \"תרופה\".", "No words yet. Add your name, grandchildren’s names, or words like “medicine”."))
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
                        Label(tr("להוסיף: \(word)", "Add: \(word)"), systemImage: "plus.circle")
                    }
                }
            }

            if !viewModel.keywordHits.isEmpty {
                Section(tr("נשמעו לאחרונה", "Recently heard")) {
                    ForEach(viewModel.keywordHits.suffix(10).reversed()) { hit in
                        recentHitLayout {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.match.matchedText)
                                if let name = viewModel.speakerName(for: hit) {
                                    Text(name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Date(timeIntervalSince1970: hit.timestamp).formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("keywordAlertsScreen")
        .navigationTitle(tr("מילים חשובות", "Important words"))
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
