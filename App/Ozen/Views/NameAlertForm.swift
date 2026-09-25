import SwiftUI
import OzenKit

/// Type her name (or tap "savta", grandma) and the phone buzzes when it's said. Used
/// by the walkthrough and by the caption screen's offer to phones set up
/// before the walkthrough asked.
struct NameAlertForm: View {
    let viewModel: LiveCaptionViewModel
    @State private var nameDraft = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let suggestedNames = ["סבתא", "אמא"]

    private var formLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            formLayout {
                TextField(tr("השם שלך", "Your name"), text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit(addName)
                Button(tr("להוסיף", "Add"), action: addName)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
                    .disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            formLayout {
                ForEach(Self.suggestedNames, id: \.self) { word in
                    suggestionButton(word)
                }
            }
            if !viewModel.settings.keywordAlerts.isEmpty {
                Label(addedText, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var addedText: String {
        tr("הטלפון ירטוט על: ", "The phone will vibrate for: ") + viewModel.settings.keywordAlerts.map(\.phrase).joined(separator: ", ")
    }

    private func suggestionButton(_ word: String) -> some View {
        let added = viewModel.settings.keywordAlerts.contains {
            HebrewText.normalize($0.phrase) == HebrewText.normalize(word)
        }
        return Button {
            viewModel.addKeywordAlert(phrase: word)
        } label: {
            Label(word, systemImage: added ? "checkmark" : "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(added)
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
    }

    private func addName() {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        viewModel.addKeywordAlert(phrase: name)
        // A name the engine has never heard is spelled some other way, and
        // then never matches; on the names list, both engines expect it.
        viewModel.addVocabularyTerm(name)
        nameDraft = ""
    }
}

/// The caption screen's offer, as a sheet: the form, and a way out.
struct NameAlertSheet: View {
    let viewModel: LiveCaptionViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(tr("כשמישהו אומר את השם שלך, הטלפון רוטט והשורה מסומנת, גם כשלא מסתכלים על המסך.", "When someone says your name, the phone vibrates and the line is marked, even when you’re not looking at the screen."))
                    NameAlertForm(viewModel: viewModel)
                    Text(tr("אפשר להוסיף עוד מילים, או למחוק, בהגדרות ← התראות ← מילים חשובות.", "You can add more words, or delete them, in Settings → Alerts → Important words."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .font(.title3)
                .padding(24)
            }
            .navigationTitle(tr("כשקוראים לך", "When your name is called"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("סיום", "Done")) { dismiss() }
                }
            }
        }
    }
}
