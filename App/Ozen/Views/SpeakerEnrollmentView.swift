import SwiftUI
import OzenKit

/// One-time voice enrollment: record ~30 s through the live capture path,
/// extract an embedding, save it as a named profile so that person's turns
/// are labeled from the very first utterance.
struct SpeakerEnrollmentView: View {
    let viewModel: LiveCaptionViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isRecording = false
    @State private var progress: Double = 0
    @State private var failed = false

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
                        Text("בקשו מהאדם לדבר בטבעיות, במרחק רגיל מהמיקרופון שנבחר. הכתוביות מושהות בזמן ההקלטה.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
                    Button("ביטול") { dismiss() }
                        .disabled(isRecording)
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
        Task {
            let saved = await viewModel.enroll(
                name: name.trimmingCharacters(in: .whitespaces),
                seconds: targetSeconds
            ) { fraction in
                progress = fraction
            }
            isRecording = false
            if saved {
                dismiss()
            } else {
                failed = true
            }
        }
    }
}
