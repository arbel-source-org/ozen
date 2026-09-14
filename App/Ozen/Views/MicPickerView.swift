import SwiftUI
import OzenKit

/// Explicit input selection — the single most concrete gap in the apps
/// this replaces. Every available input is listed and tappable, nothing is
/// hidden behind an automatic default, and a live level meter shows
/// whether the selected mic is actually hearing anything.
struct MicPickerView: View {
    let viewModel: LiveCaptionViewModel
    @Environment(\.dismiss) private var dismiss
    /// The microphone last tapped that the phone wouldn't switch to.
    @State private var refusedInputName: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(viewModel.availableInputs) { input in
                        Button {
                            refusedInputName = viewModel.selectInput(uid: input.uid) ? nil : input.portName
                        } label: {
                            InputRow(input: input, isSelected: input.uid == viewModel.selectedInputUID)
                        }
                        .foregroundStyle(.primary)
                    }
                    if let refusedInputName {
                        Label(tr("הטלפון לא עבר ל\"\(refusedInputName)\", והמיקרופון המסומן עדיין מקליט. נסו לנתק ולחבר אותו שוב.", "The phone did not switch to “\(refusedInputName)”, and the marked microphone is still recording. Try unplugging and reconnecting it."), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                } header: {
                    Text(tr("מיקרופונים זמינים", "Available microphones"))
                } footer: {
                    Text(tr("המיקרופון המסומן הוא זה שמקליט עכשיו. אוזניות או מיקרופון שיתחברו יופיעו כאן אוטומטית.", "The marked microphone is the one recording now. Headphones or a microphone that connect will appear here automatically."))
                }

                Section(tr("עוצמת קליטה", "Input level")) {
                    LevelMeter(level: viewModel.inputLevel, isActive: viewModel.isListening)
                    if viewModel.isListening {
                        Text(tr("דברו ותראו את הפס זז. אם הוא לא זז, המיקרופון שנבחר לא שומע.", "Speak and watch the bar move. If it doesn’t move, the selected microphone isn’t hearing anything."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(tr("המד פעיל רק בזמן האזנה.", "The meter is only active while listening."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(tr("טיפים", "Tips")) {
                    Label {
                        Text(tr("מיקרופון USB‑C צריך להיות מסוג \"USB Audio\" (כמו רוב מיקרופוני הדש). אם הוא לא מופיע ברשימה, האייפון לא מזהה אותו בכלל, ולא רק האפליקציה.", "A USB‑C microphone needs to be of the “USB Audio” type (like most lapel mics). If it doesn’t appear in the list, the iPhone isn’t recognizing it at all, not just the app."))
                    } icon: {
                        Image(systemName: "cable.connector")
                    }
                    Label {
                        Text(tr("AirPods מופיעים כשהם באוזניים ומחוברים. איכות ההקלטה דרכם נמוכה יותר מאשר מיקרופון חוטי.", "AirPods appear when they’re in the ears and connected. Recording quality through them is lower than a wired microphone."))
                    } icon: {
                        Image(systemName: "airpodspro")
                    }
                }
                .font(.footnote)
            }
            .overlay {
                if viewModel.availableInputs.isEmpty {
                    ContentUnavailableView {
                        Label(tr("אין מיקרופונים זמינים", "No microphones available"), systemImage: "mic.slash")
                    } description: {
                        Text(tr("אם האפליקציה עדיין מתחילה, חכו רגע. אחרת חברו אוזניות או מיקרופון חיצוני והקישו על רענון.", "If the app is still starting up, wait a moment. Otherwise, connect headphones or an external microphone and tap refresh."))
                    }
                }
            }
            // Opened before captions ever set up the microphone, the list
            // would otherwise be empty until someone found the refresh button.
            .onAppear { viewModel.refreshInputs() }
            .navigationTitle(tr("בחירת מיקרופון", "Choose microphone"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("סגור", "Close")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.refreshInputs()
                    } label: {
                        Label(tr("רענון", "Refresh"), systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }

    static func icon(for type: AudioPortType) -> String {
        switch type {
        case .builtInMic: return "iphone"
        case .bluetooth: return "airpodspro"
        case .wired: return "headphones"
        case .usb: return "cable.connector"
        case .hearingAid: return "ear"
        case .other: return "mic"
        }
    }

    static func typeName(for type: AudioPortType) -> String {
        switch type {
        case .builtInMic: return tr("מובנה", "Built-in")
        case .bluetooth: return "Bluetooth"
        case .wired: return tr("חוטי", "Wired")
        case .usb: return "USB"
        case .hearingAid: return tr("מכשיר שמיעה", "Hearing aid")
        case .other: return tr("אחר", "Other")
        }
    }

    /// What fits in the control bar: the system's own name for the port
    /// is fine for accessories ("Grandma's AirPods"), but the built-in one
    /// is called "iPhone Microphone", which is too long and says nothing.
    static func shortName(for input: AudioInputDescriptor) -> String {
        switch input.portType {
        case .builtInMic: return tr("אייפון", "iPhone")
        default: return input.portName
        }
    }
}

private struct InputRow: View {
    let input: AudioInputDescriptor
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: MicPickerView.icon(for: input.portType))
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(input.portName)
                Text(MicPickerView.typeName(for: input.portType))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A plain horizontal level bar with a peak-hold tick, refreshed as fast
/// as the audio layer publishes (about 20 Hz).
struct LevelMeter: View {
    let level: Float
    let isActive: Bool
    @State private var peak: Float = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(isActive ? meterColor : Color.secondary)
                    .frame(width: geometry.size.width * CGFloat(isActive ? level : 0))
                    .animation(.linear(duration: 0.05), value: level)
                if isActive && peak > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.7))
                        .frame(width: 2)
                        .offset(x: geometry.size.width * CGFloat(peak) - 1)
                }
            }
        }
        .frame(height: 14)
        .onChange(of: level) { _, newLevel in
            if newLevel >= peak {
                peak = newLevel
            } else {
                peak = max(newLevel, peak - 0.02)
            }
        }
        .accessibilityLabel(tr("עוצמת קליטה", "Input level"))
        .accessibilityValue(tr("\(Int(level * 100)) אחוז", "\(Int(level * 100)) percent"))
    }

    private var meterColor: Color {
        switch level {
        case ..<0.15: return .gray
        case ..<0.85: return .green
        default: return .orange
        }
    }
}
