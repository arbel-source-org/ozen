import SwiftUI
import OzenKit

/// The other direction of the conversation: the reader types a reply (or
/// taps one she uses all the time) and the phone says it. Captions pause
/// while the phone talks so it doesn't caption itself.
struct TypeToSpeakView: View {
    @Bindable var viewModel: LiveCaptionViewModel
    @State private var text = ""
    /// The typed sentence last said, kept after the field clears so it can
    /// be said again when the other person didn't catch it.
    @State private var lastTyped: String?
    @State private var editingPhrases = false
    @State private var showingBigText = false
    @FocusState private var isTyping: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                composer
                    .padding(16)

                Divider()

                List {
                    Section {
                        ForEach(viewModel.settings.quickPhrases, id: \.self) { phrase in
                            Button {
                                viewModel.speak(phrase)
                            } label: {
                                HStack {
                                    Text(phrase)
                                        .font(.title3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "speaker.wave.2")
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .foregroundStyle(.primary)
                        }
                    } header: {
                        HStack {
                            Text("משפטים מוכנים")
                            Spacer()
                            Button(editingPhrases ? "סיום" : "עריכה") { editingPhrases.toggle() }
                                .font(.subheadline.weight(.semibold))
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                    }

                    if editingPhrases {
                        QuickPhrasesEditor(viewModel: viewModel)
                    }
                }
            }
            .navigationTitle("להגיד משהו")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("סגור") { dismiss() }
                }
            }
            .onAppear { isTyping = true }
        }
        .presentationDetents([.medium, .large])
        .fullScreenCover(isPresented: $showingBigText) {
            BigTextView(
                text: $text,
                display: viewModel.display,
                canSpeak: viewModel.hasHebrewVoice,
                onSpeak: { viewModel.speak($0) }
            )
            .alertOverlay(for: viewModel)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("הקלידו מה להגיד…", text: $text, axis: .vertical)
                .font(.title2)
                .lineLimit(1...4)
                .focused($isTyping)
                .submitLabel(.send)
                .onSubmit(speakTyped)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                if viewModel.isSpeaking {
                    Button {
                        viewModel.stopSpeaking()
                    } label: {
                        Label("עצירה", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                Button(action: speakTyped) {
                    Label("להשמיע", systemImage: "speaker.wave.3.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let lastTyped {
                sayAgainRow(lastTyped)
            }

            Button {
                isTyping = false
                showingBigText = true
            } label: {
                Label("מסך מלא באותיות גדולות", systemImage: "textformat.size.larger")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("כדי שמישהו יכתוב לך, או כדי להראות למי שמולך מה כתבת")

            if !viewModel.hasHebrewVoice {
                Label("אין קול עברי מותקן. הגדרות → נגישות → תוכן מדובר → קולות → עברית.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func sayAgainRow(_ phrase: String) -> some View {
        HStack(spacing: 12) {
            Button {
                viewModel.speak(phrase)
            } label: {
                Label(phrase, systemImage: "arrow.counterclockwise")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("להשמיע שוב: \(phrase)")

            if !viewModel.settings.quickPhrases.contains(phrase) {
                Button {
                    viewModel.addQuickPhrase(phrase)
                } label: {
                    Image(systemName: "plus.bubble")
                        .frame(minWidth: 44, minHeight: 32)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("להוסיף למשפטים המוכנים")
            }
        }
    }

    private func speakTyped() {
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        viewModel.speak(phrase)
        lastTyped = phrase
        text = ""
    }
}

private struct QuickPhrasesEditor: View {
    @Bindable var viewModel: LiveCaptionViewModel
    @State private var newPhrase = ""

    var body: some View {
        Section("עריכת המשפטים") {
            HStack {
                TextField("משפט חדש", text: $newPhrase)
                    .onSubmit(add)
                Button(action: add) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("הוספה")
                .disabled(newPhrase.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(viewModel.settings.quickPhrases, id: \.self) { phrase in
                Text(phrase)
            }
            .onDelete { offsets in
                viewModel.removeQuickPhrases(at: offsets)
            }
            .onMove { from, to in
                viewModel.moveQuickPhrases(from: from, to: to)
            }
            Button("לשחזר את ברירת המחדל") {
                viewModel.resetQuickPhrases()
            }
        }
    }

    private func add() {
        viewModel.addQuickPhrase(newPhrase)
        newPhrase = ""
    }
}
