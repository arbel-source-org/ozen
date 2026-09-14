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
                Section("שם") {
                    TextField("לדוגמה: סבתא", text: $name)
                        .textInputAutocapitalization(.words)
                        .disabled(isRecording)
                }

                Section {
                    if isRecording {
                        ProgressView(value: progress) {
                            Text("מקליט… \(Int(progress * targetSeconds))/\(Int(targetSeconds)) שניות")
                        }
                        LevelMeter(level: viewModel.inputLevel, isActive: true)
                        Text("בקשו מהאדם לדבר בטבעיות, במרחק רגיל מהמיקרופון שנבחר. אם הפס לא זז כשמדברים, המיקרופון לא שומע. הכתוביות מושהות בזמן ההקלטה.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("עצירה בלי לשמור", role: .destructive) {
                            recording?.cancel()
                        }
                    } else {
                        Button {
                            record()
                        } label: {
                            Label("הקלטה ושמירה (\(Int(targetSeconds)) שניות)", systemImage: "record.circle")
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("הקלטה")
                } footer: {
                    Text("ההקלטה עצמה לא נשמרת — רק \"טביעת קול\" מספרית קצרה שממנה אי אפשר לשחזר את הדיבור.")
                }
            }
            .navigationTitle("דובר חדש")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isRecording)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ביטול") {
                        recording?.cancel()
                        dismiss()
                    }
                }
            }
            .alert("ההקלטה קצרה או שקטה מדי", isPresented: $failed) {
                Button("נסו שוב", role: .cancel) {}
            } message: {
                Text("לא הצלחנו להפיק טביעת קול. ודאו שהמיקרופון הנכון נבחר ושהאדם מדבר לאורך כל ההקלטה.")
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
