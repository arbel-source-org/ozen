import SwiftUI
import OzenKit

/// Explicit input selection — the single most concrete gap in the apps
/// this replaces. Every available input is listed and tappable, nothing is
/// hidden behind an automatic default, and a live level meter shows
/// whether the selected mic is actually hearing anything.
struct MicPickerView: View {
    let viewModel: LiveCaptionViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(viewModel.availableInputs) { input in
                        Button {
                            viewModel.selectInput(uid: input.uid)
                        } label: {
                            InputRow(input: input, isSelected: input.uid == viewModel.selectedInputUID)
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("מיקרופונים זמינים")
                } footer: {
                    Text("המיקרופון המסומן הוא זה שמקליט עכשיו. אוזניות או מיקרופון שיתחברו יופיעו כאן אוטומטית.")
                }

                Section("עוצמת קליטה") {
                    LevelMeter(level: viewModel.inputLevel, isActive: viewModel.isListening)
                    if viewModel.isListening {
                        Text("דברו ותראו את הפס זז. אם הוא לא זז, המיקרופון שנבחר לא שומע.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("המד פעיל רק בזמן האזנה.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("טיפים") {
                    Label {
                        Text("מיקרופון USB‑C צריך להיות מסוג \"USB Audio\" (רוב מיקרופוני הדש הם). אם הוא לא מופיע ברשימה, האייפון לא מזהה אותו בכלל, ולא רק האפליקציה.")
                    } icon: {
                        Image(systemName: "cable.connector")
                    }
                    Label {
                        Text("AirPods מופיעים כשהם באוזניים ומחוברים. איכות ההקלטה דרכם נמוכה יותר מאשר מיקרופון חוטי.")
                    } icon: {
                        Image(systemName: "airpodspro")
                    }
                }
                .font(.footnote)
            }
            .overlay {
                if viewModel.availableInputs.isEmpty {
                    ContentUnavailableView(
                        "אין מיקרופונים זמינים",
                        systemImage: "mic.slash",
                        description: Text("אם האפליקציה עדיין מתחילה, חכו רגע. אחרת חברו אוזניות או מיקרופון חיצוני והקישו על רענון.")
                    )
                }
            }
            .navigationTitle("בחירת מיקרופון")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("סגור") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.refreshInputs()
                    } label: {
                        Label("רענון", systemImage: "arrow.clockwise")
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
        case .builtInMic: return "מובנה"
        case .bluetooth: return "Bluetooth"
        case .wired: return "חוטי"
        case .usb: return "USB"
        case .hearingAid: return "מכשיר שמיעה"
        case .other: return "אחר"
        }
    }

    /// What fits in the control bar: the system's own name for the port
    /// is fine for accessories ("AirPods של סבתא"), but the built-in one
    /// is called "iPhone Microphone", which is too long and says nothing.
    static func shortName(for input: AudioInputDescriptor) -> String {
        switch input.portType {
        case .builtInMic: return "אייפון"
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
        .accessibilityLabel("עוצמת קליטה")
        .accessibilityValue("\(Int(level * 100)) אחוז")
    }

    private var meterColor: Color {
        switch level {
        case ..<0.15: return .gray
        case ..<0.85: return .green
        default: return .orange
        }
    }
}
