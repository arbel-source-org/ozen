import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct OzenWidgetBundle: WidgetBundle {
    var body: some Widget {
        CaptionLiveActivity()
        if #available(iOS 18.0, *) {
            StartCaptionsControl()
        }
    }
}

/// A button for Control Center, or in place of the flashlight or camera on
/// the lock screen, that opens Ozen and starts captions: one press when
/// someone starts talking, instead of finding the app.
@available(iOS 18.0, *)
struct StartCaptionsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.arbelonson.ozen.Ozen.Captions.start") {
            ControlWidgetButton(action: StartCaptionsIntent()) {
                Label("כתוביות", systemImage: "captions.bubble.fill")
            }
        }
        .displayName("התחלת כתוביות")
        .description("פותח את אוזן ומתחיל לכתב את השיחה.")
    }
}

/// The newest caption lines on the lock screen and in the Dynamic Island,
/// so she can read the last sentence without unlocking the phone.
struct CaptionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CaptionActivityAttributes.self) { context in
            CaptionLinesView(state: context.state, isStale: context.isStale, fontSize: context.state.large ? 27 : 21)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    // Less room than the lock screen: the newest line only.
                    CaptionLinesView(state: context.state, isStale: context.isStale, fontSize: 17, newestOnly: true)
                }
            } compactLeading: {
                // Marks only: VoiceOver reads the activity's lines instead.
                Image(systemName: "captions.bubble.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
            } compactTrailing: {
                Image(systemName: "ear")
                    .accessibilityHidden(true)
            } minimal: {
                Image(systemName: "captions.bubble.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel(context.state.english ? "Ozen" : "אוזן")
            }
        }
    }
}

/// White text on black, like the caption screen: a line still being
/// written is dimmer, and a name heads a speaker's run in yellow.
struct CaptionLinesView: View {
    let state: CaptionActivityAttributes.ContentState
    let isStale: Bool
    let fontSize: CGFloat
    var newestOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.lines.isEmpty {
                // "Listening" under "captions are starting" or "paused
                // because of a call" would say the opposite of the note.
                if state.status == nil {
                    listeningLabel
                }
            } else {
                ForEach(Array(shownLines.enumerated()), id: \.offset) { offset, line in
                    let isNewest = offset == shownLines.count - 1
                    lineText(line)
                        .font(.system(size: fontSize, weight: .semibold))
                        // The app cuts each line to about this many lines
                        // (`LockScreenCaptions`); a wide one shrinks a little
                        // rather than lose its end, the newest words.
                        .lineLimit(isNewest ? 3 : (state.large ? 1 : 2))
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let status = state.status {
                note(status)
            } else if isStale {
                // The app stopped updating the lines (iOS closed it, say):
                // they may be long out of date.
                note(state.english ? "Captions aren’t updating. Open Ozen." : "הכתוביות לא מתעדכנות. פתחו את אוזן.")
            } else if let ageNote = state.ageNote {
                // Captions run, but nobody has spoken for a while.
                note(ageNote, color: .white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.layoutDirection, .rightToLeft)
    }

    /// A note under the lines: why they stopped coming, or how long ago
    /// they were said. Follows the phone's text size, up to
    /// where it would crowd the lines out of the lock screen's room.
    private func note(_ text: String, color: Color = .orange) -> some View {
        Text(text)
            .font(.system(.subheadline, weight: .semibold))
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .foregroundStyle(color)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
    }

    private var listeningLabel: some View {
        Label(state.english ? "Listening…" : "מקשיב…", systemImage: "ear")
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white.opacity(0.8))
    }

    /// Only the newest line under a note (two caption lines fill the lock
    /// screen's room, leaving none for it) and in the Dynamic Island.
    private var shownLines: [CaptionActivityAttributes.ContentState.Line] {
        guard newestOnly || state.status != nil || isStale, var newest = state.lines.last else {
            return state.lines
        }
        if newest.speaker == nil, state.lines.count > 1 {
            // No name on a line means the speaker of the line above it.
            newest.speaker = state.lines[state.lines.count - 2].speaker
        }
        return [newest]
    }

    private func lineText(_ line: CaptionActivityAttributes.ContentState.Line) -> Text {
        let words = Text(line.text)
            .foregroundColor(line.isFinal ? .white : .white.opacity(0.7))
        guard let speaker = line.speaker else { return words }
        return Text("\(speaker): ").foregroundColor(.yellow) + words
    }
}
