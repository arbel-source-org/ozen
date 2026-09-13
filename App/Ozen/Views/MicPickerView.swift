import SwiftUI
import OzenKit

/// Explicit input selection — the single most concrete gap in the apps
/// this replaces. Every available input is listed and tappable; nothing is
/// hidden behind an automatic default.
struct MicPickerView: View {
    let viewModel: LiveCaptionViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(viewModel.availableInputs) { input in
                Button {
                    viewModel.selectInput(uid: input.uid)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: icon(for: input.portType))
                        Text(input.portName)
                        Spacer()
                        if input.uid == viewModel.selectedInputUID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .overlay {
                if viewModel.availableInputs.isEmpty {
                    ContentUnavailableView(
                        "אין מיקרופונים זמינים",
                        systemImage: "mic.slash",
                        description: Text("חברו אוזניות או מיקרופון חיצוני ונסו שוב.")
                    )
                }
            }
            .navigationTitle("בחירת מיקרופון")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("סגור") { dismiss() }
                }
            }
        }
    }

    private func icon(for type: AudioPortType) -> String {
        switch type {
        case .builtInMic: return "mic"
        case .bluetooth: return "airpodspro"
        case .wired: return "cable.connector"
        case .usb: return "cable.connector.horizontal"
        case .hearingAid: return "ear"
        case .other: return "mic"
        }
    }
}
