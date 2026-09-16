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
                            Text(tr("משפטים מוכנים", "Quick phrases"))
                            Spacer()
                            Button(editingPhrases ? tr("סיום", "Done") : tr("עריכה", "Edit")) { editingPhrases.toggle() }
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
            .accessibilityIdentifier("typeToSpeakScreen")
            .navigationTitle(tr("להגיד משהו", "Say something"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("סגור", "Close")) { dismiss() }
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
            TextField(tr("הקלידו מה להגיד…", "Type what to say…"), text: $text, axis: .vertical)
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
                        Label(tr("עצירה", "Stop"), systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .ozenGlassButton()
                    .controlSize(.large)
                }
                Button(action: speakTyped) {
                    Label(tr("להשמיע", "Play"), systemImage: "speaker.wave.3.fill")
                        .frame(maxWidth: .infinity)
                }
                .ozenGlassButton(prominent: true)
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
                Label(tr("מסך מלא באותיות גדולות", "Full screen, big letters"), systemImage: "textformat.size.larger")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .ozenGlassButton()
            .accessibilityHint(tr("כדי שמישהו יכתוב לך, או כדי להראות למי שמולך מה כתבת", "So someone can write to you, or to show the person you’re talking with what you wrote"))

            if !viewModel.hasHebrewVoice {
                Label(tr("אין קול עברי מותקן. הגדרות ← נגישות ← תוכן מדובר ← קולות ← עברית.", "No Hebrew voice installed. Settings ← Accessibility ← Spoken Content ← Voices ← Hebrew."), systemImage: "exclamationmark.triangle")
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
            .ozenGlassButton()
            .accessibilityLabel(tr("להשמיע שוב: \(phrase)", "Play again: \(phrase)"))

            if !viewModel.settings.quickPhrases.contains(phrase) {
                Button {
                    viewModel.addQuickPhrase(phrase)
                } label: {
                    Image(systemName: "plus.bubble")
                        .frame(minWidth: 44, minHeight: 32)
                }
                .ozenGlassButton()
                .accessibilityLabel(tr("להוסיף למשפטים המוכנים", "Add to quick phrases"))
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
    @State private var confirmingReset = false

    var body: some View {
        Section(tr("עריכת המשפטים", "Edit phrases")) {
            HStack {
                TextField(tr("משפט חדש", "New phrase"), text: $newPhrase)
                    .onSubmit(add)
                Button(action: add) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(tr("הוספה", "Add"))
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
            Button(tr("לשחזר את ברירת המחדל", "Restore defaults"), role: .destructive) {
                confirmingReset = true
            }
            .disabled(viewModel.settings.quickPhrases == AppSettings.defaultQuickPhrases)
            .confirmationDialog(tr("לשחזר את המשפטים המוכנים?", "Restore the default phrases?"), isPresented: $confirmingReset, titleVisibility: .visible) {
                Button(tr("לשחזר", "Restore"), role: .destructive) {
                    viewModel.resetQuickPhrases()
                }
            } message: {
                Text(tr("המשפטים שנוספו או שונו יימחקו.", "Phrases that were added or changed will be deleted."))
            }
        }
    }

    private func add() {
        viewModel.addQuickPhrase(newPhrase)
        newPhrase = ""
    }
}
