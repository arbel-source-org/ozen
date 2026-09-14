import SwiftUI
import OzenKit

/// Type her name (or tap "סבתא") and the phone buzzes when it's said. Used
/// by the walkthrough and by the caption screen's offer to phones set up
/// before the walkthrough asked.
struct NameAlertForm: View {
    let viewModel: LiveCaptionViewModel
    @State private var nameDraft = ""

    private static let suggestedNames = ["סבתא", "אמא"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                TextField("השם שלך", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit(addName)
                Button("להוסיף", action: addName)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 10) {
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
        "הטלפון ירטוט על: " + viewModel.settings.keywordAlerts.map(\.phrase).joined(separator: ", ")
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
                    Text("כשמישהו אומר את השם שלך, הטלפון רוטט והשורה מסומנת, גם כשלא מסתכלים על המסך.")
                    NameAlertForm(viewModel: viewModel)
                    Text("אפשר להוסיף עוד מילים, או למחוק, בהגדרות ← התראות ← מילים חשובות.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .font(.title3)
                .padding(24)
            }
            .navigationTitle("כשקוראים לך")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("סיום") { dismiss() }
                }
            }
        }
    }
}
