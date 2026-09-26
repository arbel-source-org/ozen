import SwiftUI
import OzenKit

/// One utterance. `isCommitted` drives the only visual difference that
/// matters here: committed text is at full strength and permanent, pending
/// text is dimmer to signal "still settling" — nothing is ever truncated in
/// either state. Only the colour changes, never the slant or weight: Hebrew
/// has no italic, so iOS would skew the letters of the very line being read,
/// and a change of weight re-wraps the line at the moment it locks in.
struct CaptionRow: View {
    let segment: TranscriptSegment
    let speakerName: String?
    let showsSpeakerLabel: Bool
    let display: DisplayPreferences
    let theme: CaptionTheme
    let isKeywordHit: Bool
    let isStarred: Bool
    let isUncertain: Bool
    var marksUncertainWords = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsSpeakerLabel, let speakerName {
                HStack(spacing: 6) {
                    Text(speakerName)
                        .font(.system(size: max(15, display.fontSize * 0.5), weight: .semibold))
                    Circle()
                        .frame(width: 10, height: 10)
                }
                .foregroundStyle(SpeakerColor.color(forClusterID: segment.speakerClusterID, speakerName: speakerName, on: theme.colorScheme))
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isStarred {
                    Image(systemName: "star.fill")
                        .font(.system(size: max(14, display.fontSize * 0.6)))
                        .foregroundStyle(Color.yellow.readable(on: theme.colorScheme))
                }
                if isKeywordHit {
                    // The yellow field alone is easy to miss scrolling back
                    // with weak eyes; a bell marks the line the way the star
                    // and question mark mark theirs.
                    Image(systemName: "bell.fill")
                        .font(.system(size: max(14, display.fontSize * 0.6)))
                        .foregroundStyle(theme.text)
                }
                if isUncertain {
                    // Not a colour change: the words stay as readable as
                    // every other line, with a mark saying they may be wrong.
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: max(14, display.fontSize * 0.6)))
                        .foregroundStyle(theme.pendingText)
                }
                Text(
                    caption: CaptionLayout.displayText(segment.text),
                    emphasizingNumbers: display.emphasizeNumbers,
                    size: display.fontSize,
                    // A line still being written keeps its dimmer colour
                    // throughout, numbers included, so it reads as unfinished.
                    numberColor: segment.isCommitted ? theme.numberText : nil,
                    uncertainWords: marksUncertainWords && segment.isCommitted ? segment.uncertainWords : []
                )
                    .font(.system(size: display.fontSize, weight: display.boldText ? .bold : .medium))
                    .foregroundStyle(segment.isCommitted ? theme.text : theme.pendingText)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(display.fontSize * 0.15)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, isKeywordHit ? 8 : 0)
                    .padding(.vertical, isKeywordHit ? 4 : 0)
                    .background(
                        // A keyword line keeps a soft yellow field behind it,
                        // so the reader can find "where my name was said"
                        // after the buzz, even a screenful later.
                        isKeywordHit ? Color.yellow.opacity(theme.colorScheme == .dark ? 0.22 : 0.35) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Hebrew speech reads from the right, whatever language the
        // buttons around it are in.
        .environment(\.layoutDirection, .rightToLeft)
        .accessibilityElement(children: .ignore)
        // VoiceOver reads the speaker on every line, even where the
        // screen leaves the repeated name out.
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(isKeywordHit ? tr("מכילה מילה חשובה", "Contains an important word") : "")
    }

    private var accessibilityText: String {
        var line = speakerName.map { "\($0): \(segment.text)" } ?? segment.text
        if isUncertain { line = tr("ייתכן שלא נשמע נכון. ", "May not have been heard correctly. ") + line }
        return isStarred ? tr("מסומן כחשוב. \(line)", "Marked as important. \(line)") : line
    }
}

struct NameSpeakerSheet: View {
    let segment: TranscriptSegment
    let viewModel: LiveCaptionViewModel
    @State private var name = ""
    @FocusState private var typing: Bool
    @Environment(\.dismiss) private var dismiss

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var canSave: Bool { !trimmedName.isEmpty && segment.speakerClusterID != nil }

    /// Someone already saved, split off as a new "speaker 3": one tap puts
    /// the right name back instead of typing it again.
    private var savedNames: [String] {
        SavedSpeaker.grouping(viewModel.settings.speakerProfiles).map(\.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(CaptionLayout.displayText(segment.text))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } header: {
                    Text(tr("מי אמר את זה?", "Who said this?"))
                }
                Section {
                    TextField(tr("שם", "Name"), text: $name)
                        .textInputAutocapitalization(.words)
                        .focused($typing)
                        .submitLabel(.done)
                        .onSubmit { if canSave { save() } }
                } footer: {
                    Text(segment.speakerClusterID == nil
                         ? tr("עדיין לא זוהה קול לשורה הזו. נסו שוב אחרי שידברו עוד קצת.", "No voice has been identified for this line yet. Try again after the person talks a bit more.")
                         : tr("מעכשיו כל מה שהקול הזה יגיד יופיע עם השם הזה.", "From now on, everything this voice says will show with this name."))
                }
                if segment.speakerClusterID != nil, !savedNames.isEmpty {
                    Section(tr("דוברים שמורים", "Saved speakers")) {
                        ForEach(savedNames, id: \.self) { saved in
                            Button {
                                name = saved
                                save()
                            } label: {
                                Label(saved, systemImage: "person.wave.2")
                            }
                        }
                    }
                }
            }
            .navigationTitle(tr("שם לדובר", "Name the speaker"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("שמירה", "Save"), action: save)
                        .disabled(!canSave)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("ביטול", "Cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            // Focus asked for while the sheet is still sliding up is often
            // dropped: wait for it to settle.
            try? await Task.sleep(for: .milliseconds(400))
            typing = segment.speakerClusterID != nil && savedNames.isEmpty
        }
    }

    private func save() {
        viewModel.nameSpeaker(of: segment, name: trimmedName)
        dismiss()
    }
}

/// Closes the loop from "the captions got this wrong" to "teach it the
/// right word": the mis-heard line for reference, and a field for the word
/// or name that should have come out, straight into Vocabulary
/// (`VocabularyHints`) so the next mention of it is more likely to land.
struct FixVocabularyWordSheet: View {
    let segment: TranscriptSegment
    let viewModel: LiveCaptionViewModel
    @State private var word = ""
    @FocusState private var typing: Bool
    @Environment(\.dismiss) private var dismiss

    private var trimmedWord: String { word.trimmingCharacters(in: .whitespaces) }
    private var canSave: Bool { !trimmedWord.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(CaptionLayout.displayText(segment.text))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } header: {
                    Text(tr("מה נכתב בכתוביות", "What the captions showed"))
                }
                Section {
                    TextField(tr("המילה או השם הנכונים", "The correct word or name"), text: $word)
                        .textInputAutocapitalization(.words)
                        .focused($typing)
                        .submitLabel(.done)
                        .onSubmit { if canSave { save() } }
                } footer: {
                    Text(tr("מהמשפט הבא, הכתוביות ינסו לזהות את המילה הזו נכון.", "From the next sentence, the captions will try to recognize this word correctly."))
                }
            }
            .navigationTitle(tr("תיקון מילה", "Fix a word"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("הוספה", "Add"), action: save)
                        .disabled(!canSave)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("ביטול", "Cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            // Focus asked for while the sheet is still sliding up is often
            // dropped: wait for it to settle (see NameSpeakerSheet).
            try? await Task.sleep(for: .milliseconds(400))
            typing = true
        }
    }

    private func save() {
        viewModel.addVocabularyTerm(trimmedWord)
        dismiss()
    }
}

/// The sound-event banner: big icon, the Hebrew name, importance colour.
/// Tapping dismisses. Critical alerts (sirens, smoke detector) are red and
/// stay longer; everything else is calm.
struct SoundAlertBanner: View {
    let alert: SoundAlert
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            HStack(spacing: 14) {
                Image(systemName: alert.event.systemImage)
                    .font(.system(size: 30, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.event.name)
                        .font(.title3.weight(.bold))
                    Text(alert.event.importance == .critical ? tr("שימו לב!", "Attention!") : tr("נשמע עכשיו", "Heard just now"))
                        .font(.subheadline)
                        .opacity(0.85)
                }
                Spacer()
                Image(systemName: "xmark")
                    .font(.headline)
                    .opacity(0.7)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            // White on the system orange of a doorbell alert is under 3:1;
            // the deeper shade keeps the words readable at a glance.
            .background(SoundAlertsView.tint(alert.event.importance).deepShade.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr("התראה: \(alert.event.name)", "Alert: \(alert.event.name)"))
        .accessibilityHint(tr("הקישו לסגירה", "Tap to close"))
    }
}

/// Flashes the edge of the whole screen when a safety or door sound is
/// heard (see `AlertFlash`), so it's noticed without looking at the
/// banner. Only new alerts flash, not one that was already there when the
/// screen appeared. Takes no touches, and is invisible when dark.
struct AlertFlashOverlay: View {
    let alert: SoundAlert?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flashing: SoundAlert?
    /// Kept after a flash ends, so its last fade doesn't change colour.
    @State private var tint = SoundEvent.Importance.critical
    @State private var isLit = false

    var body: some View {
        Rectangle()
            .strokeBorder(SoundAlertsView.tint(tint), lineWidth: 22)
            .background(SoundAlertsView.tint(tint).opacity(0.2))
            .ignoresSafeArea()
            .opacity(isLit ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: alert?.id) { _, _ in
                // A kettle, or the door, heard during a siren's flash doesn't
                // cut it short.
                guard let alert,
                      AlertFlash.takesOver(from: flashing?.event.importance, with: alert.event.importance, reduceMotion: reduceMotion)
                else { return }
                flashing = alert
                tint = alert.event.importance
            }
            .task(id: flashing?.id) {
                guard let alert = flashing,
                      let flash = AlertFlash.pattern(for: alert.event.importance, reduceMotion: reduceMotion)
                else { return }
                // A newer alert cancels this run, but a cancelled task still
                // wakes up: only the run for the alert still flashing may
                // touch the light, or this one's "off" could land on the
                // newer one's first flash.
                let id = alert.id
                // Over, or the screen went away: the next alert flashes
                // whatever it is, and coming back doesn't replay this one.
                defer { if flashing?.id == id { flashing = nil } }
                for _ in 0..<flash.count {
                    guard flashing?.id == id else { return }
                    withAnimation(.easeOut(duration: 0.08)) { isLit = true }
                    try? await Task.sleep(for: .seconds(flash.litSeconds))
                    guard flashing?.id == id else { return }
                    withAnimation(.easeIn(duration: 0.15)) { isLit = false }
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .seconds(flash.darkSeconds))
                    if Task.isCancelled { return }
                }
            }
    }
}

/// A small, quiet confirmation that a keyword was heard, so the buzz has
/// a visible explanation.
struct KeywordHitPill: View {
    let hit: KeywordHit
    let speakerName: String?

    var body: some View {
        Label(text, systemImage: "text.badge.star")
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.yellow.opacity(0.9), in: Capsule())
            .foregroundStyle(.black)
    }

    // A dash, not "X said" -- Hebrew's "said" is gendered and speakers
    // aren't tracked by gender.
    private var text: String {
        guard let speakerName else {
            return tr("נאמר: \(hit.match.matchedText)", "Said: \(hit.match.matchedText)")
        }
        return tr("\(speakerName) — נאמר: \(hit.match.matchedText)", "\(speakerName) said: \(hit.match.matchedText)")
    }
}
