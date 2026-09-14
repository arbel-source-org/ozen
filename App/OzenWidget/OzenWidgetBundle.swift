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
            CaptionLinesView(state: context.state, isStale: context.isStale, fontSize: 21)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    CaptionLinesView(state: context.state, isStale: context.isStale, fontSize: 17)
                }
            } compactLeading: {
                Image(systemName: "captions.bubble.fill")
                    .foregroundStyle(.yellow)
            } compactTrailing: {
                Image(systemName: "ear")
            } minimal: {
                Image(systemName: "captions.bubble.fill")
                    .foregroundStyle(.yellow)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.lines.isEmpty {
                Label("מקשיב…", systemImage: "ear")
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                ForEach(Array(state.lines.enumerated()), id: \.offset) { _, line in
                    lineText(line)
                        .font(.system(size: fontSize, weight: .semibold))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let status = state.status {
                Text(status)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.orange)
            } else if isStale {
                // The app stopped updating the lines (iOS closed it, say):
                // they may be long out of date.
                Text("הכתוביות לא מתעדכנות. פתחו את אוזן.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func lineText(_ line: CaptionActivityAttributes.ContentState.Line) -> Text {
        let words = Text(line.text)
            .foregroundColor(line.isFinal ? .white : .white.opacity(0.7))
        guard let speaker = line.speaker else { return words }
        return Text("\(speaker): ").foregroundColor(.yellow) + words
    }
}
