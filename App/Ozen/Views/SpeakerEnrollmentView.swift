import SwiftUI
import OzenKit
import OzenPlatform
import AVFoundation

/// One-time voice enrollment: record ~30-60s, extract an embedding, save it
/// as a named profile so that person's turns are labeled from the very
/// first utterance instead of only after the app happens to cluster them
/// correctly on its own.
struct SpeakerEnrollmentView: View {
    let viewModel: LiveCaptionViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isRecording = false
    @State private var secondsRecorded = 0
    @State private var recordedSamples: [Float] = []
    @State private var recorder = EnrollmentRecorder()

    private let targetSeconds = 45

    var body: some View {
        NavigationStack {
            Form {
                Section("שם") {
                    TextField("לדוגמה: סבתא", text: $name)
                }

                Section("הקלטה") {
                    if isRecording {
                        ProgressView(value: Double(secondsRecorded), total: Double(targetSeconds)) {
                            Text("מקליט... \(secondsRecorded)/\(targetSeconds) שניות")
                        }
                        Text("בקשו מהאדם לדבר בטבעיות למשך חצי דקה.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Button(recordedSamples.isEmpty ? "התחלת הקלטה" : "הקלטה מחדש") {
                            startRecording()
                        }
                    }
                }
            }
            .navigationTitle("דובר חדש")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("שמירה") {
                        viewModel.enroll(name: name, samples: recordedSamples)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || recordedSamples.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("ביטול") { dismiss() }
                }
            }
        }
    }

    private func startRecording() {
        isRecording = true
        secondsRecorded = 0
        recordedSamples = []
        recorder.start { samples in
            recordedSamples.append(contentsOf: samples)
            secondsRecorded = recordedSamples.count / 16_000
            if secondsRecorded >= targetSeconds {
                recorder.stop()
                isRecording = false
            }
        }
    }
}

/// A tiny dedicated recorder for enrollment, separate from
/// `AVAudioInputManager` since enrollment is a one-shot, foreground-only
/// capture rather than the persistent session live captioning needs.
@MainActor
final class EnrollmentRecorder {
    private let engine = AVAudioEngine()

    func start(onChunk: @escaping ([Float]) -> Void) {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
            Task { @MainActor in onChunk(samples) }
        }
        try? engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
