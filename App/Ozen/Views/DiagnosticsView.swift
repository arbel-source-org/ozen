import SwiftUI
import UIKit
import OzenKit
import OzenPlatform

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
                LabeledContent("המיקרופון נתקע", value: "\(viewModel.stats.audioStalls)")
                LabeledContent("זיהוי צלילים", value: viewModel.stats.soundDetectionRunning ? "פועל" : (viewModel.isListening ? "נעצר" : "—"))
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

            Section("התאוששות") {
                LabeledContent("ניסיון חוזר אוטומטי", value: retryText)
                LabeledContent("שיחת טלפון תופסת את האודיו", value: viewModel.isInterruptedBySystem ? "כן" : "לא")
                LabeledContent("שמירת הגדרות", value: viewModel.settingsSaveError == nil ? "תקינה" : "נכשלה")
                LabeledContent("שמירת שיחות", value: viewModel.historySaveFailure == nil ? "תקינה" : "נכשלה")
                LabeledContent("חיבור לאינטרנט", value: Self.describe(viewModel.pipeline.networkConditions))
            }

            Section {
                let lines = viewModel.pipeline.eventLog.reportLines(utcOffsetSeconds: Self.utcOffsetSeconds)
                if lines.isEmpty {
                    Text("עוד לא קרה כלום")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(lines.suffix(12).reversed().enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .environment(\.layoutDirection, .leftToRight)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } header: {
                Text("אירועים אחרונים")
            } footer: {
                Text("החדש ביותר למעלה. הדוח המועתק כולל את כל הרשימה.")
            }

            Section("מודל ומילים") {
                LabeledContent("מצב המודל", value: Self.describe(modelState))
                LabeledContent("טוקנייזר שמור", value: store.hasCachedTokenizer() ? "כן" : "לא (צריך אינטרנט פעם אחת)")
                LabeledContent("שמות ומילים", value: "\(viewModel.vocabulary.count)")
                LabeledContent("התראות מילים", value: "\(viewModel.settings.keywordAlerts.filter(\.isEnabled).count)")
            }

            Section("מכשיר") {
                LabeledContent("חום", value: Self.describe(ProcessInfo.processInfo.thermalState))
                LabeledContent("מצב חיסכון בסוללה", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "פעיל" : "כבוי")
                LabeledContent("סוללה", value: Self.batteryText)
                LabeledContent("מקום פנוי", value: Self.freeSpaceText)
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

    private let store = WhisperModelStore()

    private var modelState: ModelFolderState {
        store.state(of: viewModel.settings.whisperModelVariant)
    }

    private var retryText: String {
        guard let retry = viewModel.pipeline.scheduledRetry else { return "—" }
        let seconds = max(0, Int((retry.at - Date().timeIntervalSince1970).rounded()))
        return "ניסיון \(retry.attempt), בעוד \(seconds) שנ׳"
    }

    private static var batteryText: String {
        let device = UIDevice.current
        guard device.isBatteryMonitoringEnabled, device.batteryLevel >= 0 else { return "—" }
        let plugged = device.batteryState == .charging || device.batteryState == .full
        return "\(Int((device.batteryLevel * 100).rounded()))%\(plugged ? " · בטעינה" : "")"
    }

    private static func format(bytes: Int64) -> String {
        ModelManagerView.format(bytes: bytes)
    }

    private var eventLines: String {
        let lines = viewModel.pipeline.eventLog.reportLines(utcOffsetSeconds: Self.utcOffsetSeconds)
        return lines.isEmpty ? "-" : lines.joined(separator: "\n")
    }

    private static var utcOffsetSeconds: Int {
        TimeZone.current.secondsFromGMT(for: Date())
    }

    private static var freeSpaceText: String {
        guard let bytes = DeviceStorage.availableBytes() else { return "—" }
        return format(bytes: bytes)
    }

    static func describe(_ state: ModelFolderState) -> String {
        switch state {
        case .missing: return "לא הורד"
        case .partial: return "הורדה נקטעה"
        case .unverified: return "מותקן (לא אומת)"
        case .verified: return "מותקן"
        }
    }

    static func describe(_ thermal: ProcessInfo.ThermalState) -> String {
        switch thermal {
        case .nominal: return "רגיל"
        case .fair: return "חמים"
        case .serious: return "חם · הכתוביות מאטות"
        case .critical: return "חם מאוד · הכתוביות מאטות מאוד"
        @unknown default: return "לא ידוע"
        }
    }

    private var report: String {
        let stats = viewModel.stats
        return """
        Ozen diagnostics
        phase: \(Self.describe(viewModel.phase))
        failure: \(viewModel.phase.failure?.detail ?? "-")
        engine: \(viewModel.pipeline.activeEngineKind?.rawValue ?? "-") model: \(viewModel.settings.whisperModelVariant) lang: \(viewModel.settings.languageCode)
        input: \(viewModel.selectedInput?.portName ?? "-") of \(viewModel.availableInputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", "))
        audio chunks: \(stats.audioChunksReceived) seconds: \(String(format: "%.1f", stats.audioSecondsReceived)) input changes: \(stats.inputChanges) stalls: \(stats.audioStalls)
        tokens: \(stats.tokensReceived) committed: \(stats.segmentsCommitted) on screen: \(viewModel.segments.count) lag: \(stats.captionLagSeconds.map { String(format: "%.2f", $0) } ?? "-")
        restarts: \(stats.engineRestarts) clusters: \(viewModel.pipeline.speakerClusters.count) opened: \(stats.speakerClustersOpened)
        retry: \(viewModel.pipeline.scheduledRetry.map { "attempt \($0.attempt)" } ?? "-") interrupted: \(viewModel.isInterruptedBySystem) sound detection: \(viewModel.stats.soundDetectionRunning)
        settings save error: \(viewModel.settingsSaveError ?? "-") history save error: \(viewModel.historySaveFailure ?? "-") network: \(Self.describe(viewModel.pipeline.networkConditions)) cellular downloads: \(viewModel.allowCellularModelDownload)
        model state: \(String(describing: modelState)) tokenizer cached: \(store.hasCachedTokenizer()) vocabulary: \(viewModel.vocabulary.count)
        thermal: \(ProcessInfo.processInfo.thermalState.rawValue) low power: \(ProcessInfo.processInfo.isLowPowerModeEnabled) battery: \(Self.batteryText) free space: \(Self.freeSpaceText)
        device: \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion) app \(SettingsView.versionString)
        events (oldest first):
        \(eventLines)
        """
    }

    static func describe(_ network: NetworkConditions?) -> String {
        guard let network else { return "—" }
        guard network.isConnected else { return "אין חיבור" }
        var parts = [network.isExpensive ? "סלולרי" : "Wi-Fi"]
        if network.isConstrained { parts.append("חיסכון בנתונים") }
        return parts.joined(separator: " · ")
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
