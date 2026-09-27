import SwiftUI
import OzenKit

struct SpeakerEnrollmentView: View {
    let viewModel: LiveCaptionViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isRecording = false
    @State private var progress: Double = 0
    @State private var failed = false
    @State private var recording: Task<Void, Never>?

    private let targetSeconds = 30.0

    var body: some View {
        NavigationStack {
            Form {
                Section(tr("שם", "Name")) {
                    TextField(tr("לדוגמה: סבתא", "For example: Grandma"), text: $name)
                        .textInputAutocapitalization(.words)
                        .disabled(isRecording)
                }

                Section {
                    if isRecording {
                        ProgressView(value: progress) {
                            Text(tr("מקליט… %1/%2 שניות", "Recording… %1/%2 seconds", args: ["\(Int(progress * targetSeconds))", "\(Int(targetSeconds))"]))
                        }
                        .accessibilityValue(tr("%1 שניות", "%1 seconds", args: ["\(Int(progress * targetSeconds))"]))
                        LevelMeter(level: viewModel.inputLevel, isActive: true)
                        Text(tr("בקשו מהאדם לדבר בטבעיות, במרחק רגיל מהמיקרופון שנבחר. אם הפס לא זז כשמדברים, המיקרופון לא שומע. הכתוביות מושהות בזמן ההקלטה.", "Ask the person to speak naturally, at a normal distance from the selected microphone. If the bar doesn’t move while speaking, the microphone isn’t hearing anything. Captions are paused during recording."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(tr("עצירה בלי לשמור", "Stop without saving"), role: .destructive) {
                            recording?.cancel()
                        }
                    } else {
                        Button {
                            record()
                        } label: {
                            Label(tr("הקלטה ושמירה (%1 שניות)", "Record and save (%1 seconds)", args: ["\(Int(targetSeconds))"]), systemImage: "record.circle")
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text(tr("הקלטה", "Recording"))
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("לזיהוי טוב יותר, הקליטו כל אדם 3–4 פעמים באותו שם, בימים ובמקומות שונים: חדר שקט, עם טלוויזיה ברקע, מהצד השני של החדר.", "For better recognition, record each person 3–4 times under the same name, on different days and in different places: a quiet room, with the TV on, from across the room."))
                        Text(tr("ההקלטה עצמה לא נשמרת — רק \"טביעת קול\" מספרית קצרה שממנה אי אפשר לשחזר את הדיבור.", "The recording itself isn’t saved — only a short numeric “voiceprint” that the speech can’t be reconstructed from."))
                    }
                }
            }
            .accessibilityIdentifier("speakerEnrollmentScreen")
            .navigationTitle(tr("דובר חדש", "New speaker"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isRecording)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("ביטול", "Cancel")) {
                        recording?.cancel()
                        dismiss()
                    }
                }
            }
            .alert(tr("ההקלטה קצרה או שקטה מדי", "The recording is too short or too quiet"), isPresented: $failed) {
                Button(tr("נסו שוב", "Try again"), role: .cancel) {}
            } message: {
                Text(tr("לא הצלחנו להפיק טביעת קול. ודאו שהמיקרופון הנכון נבחר ושהאדם מדבר לאורך כל ההקלטה.", "We couldn’t produce a voiceprint. Make sure the right microphone is selected and the person speaks throughout the recording."))
            }
        }
    }

    private func record() {
        isRecording = true
        progress = 0
        recording = Task {
            let saved = await viewModel.enroll(
                name: name.trimmingCharacters(in: .whitespaces),
                seconds: targetSeconds
            ) { fraction in
                progress = fraction
            }
            isRecording = false
            if saved {
                dismiss()
            } else if !Task.isCancelled {
                failed = true
            }
        }
    }
}
