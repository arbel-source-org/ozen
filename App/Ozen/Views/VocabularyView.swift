import SwiftUI
import OzenKit

struct VocabularyView: View {
    @Bindable var viewModel: LiveCaptionViewModel
    @State private var newTerm = ""
    @FocusState private var editing: Bool

    var body: some View {
        List {
            Section {
                HStack {
                    TextField(tr("שם או מילה", "Name or word"), text: $newTerm)
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
                    .accessibilityLabel(tr("הוספה", "Add"))
                }
            } footer: {
                Text(tr("שמות של בני משפחה, שכנים, רופאים, תרופות, מקומות — כל מילה שהכתוביות מתקשות איתה. הראשונים ברשימה חשובים ביותר.", "Names of family members, neighbors, doctors, medicines, places — any word the captions struggle with. The first ones on the list matter most."))
            }

            if speakerNamesMissing {
                Section {
                    Button {
                        viewModel.addSpeakerNamesToVocabulary()
                    } label: {
                        Label(tr("להוסיף את שמות הדוברים השמורים", "Add the saved speaker names"), systemImage: "person.2.badge.plus")
                    }
                }
            }

            Section {
                if viewModel.vocabulary.isEmpty {
                    ContentUnavailableView(
                        tr("עדיין אין שמות", "No names yet"),
                        systemImage: "character.book.closed",
                        description: Text(tr("הוסיפו את השמות שנאמרים הכי הרבה בבית.", "Add the names said most often at home."))
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
                    Text(tr("הרשימה", "List"))
                    Spacer()
                    Text("\(viewModel.vocabulary.count) / \(VocabularyHints.maximumTerms)")
                        .monospacedDigit()
                }
            } footer: {
                Text(tr("השינויים נכנסים לתוקף מהמשפט הבא, בלי להפעיל מחדש.", "Changes take effect from the next sentence, without restarting."))
            }
        }
        .accessibilityIdentifier("vocabularyScreen")
        .navigationTitle(tr("שמות ומילים", "Names and words"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
        }
        .onAppear { editing = viewModel.vocabulary.isEmpty }
    }

    private var speakerNamesMissing: Bool {
        let vocabulary = viewModel.vocabulary
        let names = viewModel.settings.speakerProfiles.map(\.name)
        return VocabularyHints.normalized(vocabulary + names) != vocabulary
    }

    private func add() {
        viewModel.addVocabularyTerm(newTerm)
        newTerm = ""
    }
}
