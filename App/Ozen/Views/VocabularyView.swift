import SwiftUI
import OzenKit

/// The names list: family, neighbours, the doctor, the pharmacy, the
/// medicines. Both engines are told to expect these words, which is the
/// difference between "אבי" and "אבל" in the captions.
struct VocabularyView: View {
    @Bindable var viewModel: LiveCaptionViewModel
    @State private var newTerm = ""
    @FocusState private var editing: Bool

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("שם או מילה", text: $newTerm)
                        .focused($editing)
                        .submitLabel(.done)
                        .onSubmit(add)
                        .autocorrectionDisabled()
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("הוספה")
                }
            } footer: {
                Text("שמות של בני משפחה, שכנים, רופאים, תרופות, מקומות — כל מילה שהכתוביות מתקשות איתה. הראשונים ברשימה חשובים ביותר.")
            }

            if !viewModel.settings.speakerProfiles.isEmpty {
                Section {
                    Button {
                        viewModel.addSpeakerNamesToVocabulary()
                    } label: {
                        Label("להוסיף את שמות הדוברים השמורים", systemImage: "person.2.badge.plus")
                    }
                }
            }

            Section {
                if viewModel.vocabulary.isEmpty {
                    ContentUnavailableView(
                        "עדיין אין שמות",
                        systemImage: "character.book.closed",
                        description: Text("הוסיפו את השמות שנאמרים הכי הרבה בבית.")
                    )
                } else {
                    ForEach(viewModel.vocabulary, id: \.self) { term in
                        Text(term)
                            .font(.title3)
                    }
                    .onDelete { offsets in
                        viewModel.removeVocabulary(at: offsets)
                    }
                    .onMove { from, to in
                        viewModel.moveVocabulary(from: from, to: to)
                    }
                }
            } header: {
                HStack {
                    Text("הרשימה")
                    Spacer()
                    Text("\(viewModel.vocabulary.count) / \(VocabularyHints.maximumTerms)")
                        .monospacedDigit()
                }
            } footer: {
                Text("השינויים נכנסים לתוקף מהמשפט הבא, בלי להפעיל מחדש.")
            }
        }
        .navigationTitle("שמות ומילים")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
        }
        .onAppear { editing = viewModel.vocabulary.isEmpty }
    }

    private func add() {
        viewModel.addVocabularyTerm(newTerm)
        newTerm = ""
    }
}
