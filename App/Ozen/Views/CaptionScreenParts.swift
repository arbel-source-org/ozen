import SwiftUI
import OzenKit

/// One utterance. `isCommitted` drives the only visual difference that
/// matters here: committed text is solid and permanent, pending text is
/// dimmer and italic to signal "still settling" — nothing is ever
/// truncated in either state.
struct CaptionRow: View {
    let segment: TranscriptSegment
    let speakerName: String?
    let showsSpeakerLabel: Bool
    let display: DisplayPreferences
    let theme: CaptionTheme
    let isKeywordHit: Bool
    let isStarred: Bool
    let isUncertain: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsSpeakerLabel, let speakerName {
                HStack(spacing: 6) {
                    Text(speakerName)
                        .font(.system(size: max(15, display.fontSize * 0.5), weight: .semibold))
                    Circle()
                        .frame(width: 10, height: 10)
                }
                .foregroundStyle(SpeakerColor.color(forClusterID: segment.speakerClusterID))
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isStarred {
                    Image(systemName: "star.fill")
                        .font(.system(size: max(14, display.fontSize * 0.6)))
                        .foregroundStyle(.yellow)
                }
                if isUncertain {
                    // Not a colour change: the words stay as readable as
                    // every other line, with a mark saying they may be wrong.
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: max(14, display.fontSize * 0.6)))
                        .foregroundStyle(theme.pendingText)
                }
                Text(CaptionLayout.readableText(segment.text))
                    .font(.system(size: display.fontSize, weight: weight))
                    .italic(!segment.isCommitted)
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
        .accessibilityElement(children: .ignore)
        // VoiceOver reads the speaker on every line, even where the
        // screen leaves the repeated name out.
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(isKeywordHit ? "מכיל מילה חשובה" : "")
    }

    private var accessibilityText: String {
        var line = speakerName.map { "\($0): \(segment.text)" } ?? segment.text
        if isUncertain { line = "ייתכן שלא נשמע נכון. " + line }
        return isStarred ? "מסומן כחשוב. \(line)" : line
    }

    private var weight: Font.Weight {
        if display.boldText { return .bold }
        return segment.isCommitted ? .medium : .regular
    }
}

struct NameSpeakerSheet: View {
    let segment: TranscriptSegment
    let viewModel: LiveCaptionViewModel
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(CaptionLayout.readableText(segment.text))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } header: {
                    Text("מי אמר את זה?")
                }
                Section {
                    TextField("שם", text: $name)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text(segment.speakerClusterID == nil
                         ? "עדיין לא זוהה קול לשורה הזו. נסו שוב אחרי שהאדם ידבר עוד קצת."
                         : "מעכשיו כל מה שהקול הזה יגיד יופיע עם השם הזה.")
                }
            }
            .navigationTitle("שם לדובר")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("שמירה") {
                        viewModel.nameSpeaker(of: segment, name: name.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || segment.speakerClusterID == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("ביטול") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
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
                    Text(alert.event.importance == .critical ? "שימו לב!" : "נשמע עכשיו")
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
            .background(SoundAlertsView.tint(alert.event.importance).opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("התראה: \(alert.event.name)")
        .accessibilityHint("הקישו לסגירה")
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
    @State private var isLit = false

    var body: some View {
        Rectangle()
            .strokeBorder(SoundAlertsView.tint(flashing?.event.importance ?? .critical), lineWidth: 22)
            .background(SoundAlertsView.tint(flashing?.event.importance ?? .critical).opacity(0.2))
            .ignoresSafeArea()
            .opacity(isLit ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: alert?.id) { _, _ in
                // A kettle heard during a siren's flash doesn't cut it short.
                guard let alert, AlertFlash.pattern(for: alert.event.importance, reduceMotion: reduceMotion) != nil else { return }
                flashing = alert
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

    var body: some View {
        Label("נאמר: \(hit.match.matchedText)", systemImage: "text.badge.star")
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.yellow.opacity(0.9), in: Capsule())
            .foregroundStyle(.black)
    }
}
