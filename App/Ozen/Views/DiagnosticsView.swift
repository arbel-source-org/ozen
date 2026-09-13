import SwiftUI
import UIKit
import OzenKit

/// The numbers behind "it went quiet". Every counter the pipeline keeps,
/// plus device/app facts, with one button that copies it all as text so
/// it can be pasted into a message when asking for help.
struct DiagnosticsView: View {
    let viewModel: LiveCaptionViewModel
    @State private var copied = false

    var body: some View {
        Form {
            Section("מצב") {
                LabeledContent("שלב", value: Self.describe(viewModel.phase))
                LabeledContent("מנוע פעיל", value: viewModel.pipeline.activeEngineKind?.displayName ?? "—")
                LabeledContent("מודל Whisper", value: viewModel.settings.whisperModelVariant)
                LabeledContent("שפה", value: viewModel.settings.languageCode)
                if let failure = viewModel.phase.failure {
                    LabeledContent("פרטי תקלה") {
                        Text(failure.detail)
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                    }
                }
            }

            Section("אודיו") {
                LabeledContent("מיקרופון נבחר", value: viewModel.selectedInput?.portName ?? "—")
                LabeledContent("מיקרופונים זמינים", value: "\(viewModel.availableInputs.count)")
                ForEach(viewModel.availableInputs) { input in
                    Text("\(input.portName) · \(MicPickerView.typeName(for: input.portType))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("עוצמה עכשיו", value: String(format: "%.0f%%", viewModel.inputLevel * 100))
                LabeledContent("חבילות אודיו", value: "\(viewModel.stats.audioChunksReceived)")
                LabeledContent("שניות אודיו", value: String(format: "%.1f", viewModel.stats.audioSecondsReceived))
                LabeledContent("החלפות מיקרופון", value: "\(viewModel.stats.inputChanges)")
            }

            Section("תמלול") {
                LabeledContent("עדכונים מהמנוע", value: "\(viewModel.stats.tokensReceived)")
                LabeledContent("שורות שנסגרו", value: "\(viewModel.stats.segmentsCommitted)")
                LabeledContent("שורות על המסך", value: "\(viewModel.segments.count)")
                LabeledContent("פיגור כתוביות", value: viewModel.stats.captionLagSeconds.map { String(format: "%.1f שנ׳", $0) } ?? "—")
                LabeledContent("הפעלות מחדש", value: "\(viewModel.stats.engineRestarts)")
                LabeledContent("דוברים שזוהו", value: "\(viewModel.pipeline.speakerClusters.count)")
                LabeledContent("דוברים חדשים בסשן", value: "\(viewModel.stats.speakerClustersOpened)")
                if let started = viewModel.stats.sessionStartedAt {
                    LabeledContent("התחלת סשן", value: Date(timeIntervalSince1970: started).formatted(date: .omitted, time: .standard))
                }
            }

            Section("מכשיר") {
                LabeledContent("דגם", value: UIDevice.current.model)
                LabeledContent("iOS", value: UIDevice.current.systemVersion)
                LabeledContent("אפליקציה", value: SettingsView.versionString)
            }

            Section {
                Button {
                    UIPasteboard.general.string = report
                    copied = true
                } label: {
                    Label(copied ? "הועתק" : "העתקת הדוח", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
        }
        .navigationTitle("אבחון")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var report: String {
        let stats = viewModel.stats
        return """
        Ozen diagnostics
        phase: \(Self.describe(viewModel.phase))
        failure: \(viewModel.phase.failure?.detail ?? "-")
        engine: \(viewModel.pipeline.activeEngineKind?.rawValue ?? "-") model: \(viewModel.settings.whisperModelVariant) lang: \(viewModel.settings.languageCode)
        input: \(viewModel.selectedInput?.portName ?? "-") of \(viewModel.availableInputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", "))
        audio chunks: \(stats.audioChunksReceived) seconds: \(String(format: "%.1f", stats.audioSecondsReceived)) input changes: \(stats.inputChanges)
        tokens: \(stats.tokensReceived) committed: \(stats.segmentsCommitted) on screen: \(viewModel.segments.count) lag: \(stats.captionLagSeconds.map { String(format: "%.2f", $0) } ?? "-")
        restarts: \(stats.engineRestarts) clusters: \(viewModel.pipeline.speakerClusters.count) opened: \(stats.speakerClustersOpened)
        device: \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion) app \(SettingsView.versionString)
        """
    }

    static func describe(_ phase: PipelinePhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .requestingMicrophonePermission: return "requesting mic permission"
        case .preparingEngine(let progress):
            let fraction = progress.fraction.map { String(format: " %.0f%%", $0 * 100) } ?? ""
            return "preparing engine: \(progress.stage.rawValue)\(fraction) \(progress.detail ?? "")"
        case .startingAudio: return "starting audio"
        case .listening: return "listening"
        case .paused: return "paused"
        case .failed(let failure): return "failed: \(failure.kind.rawValue)"
        }
    }
}
