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
    /// Read once, and again after a mark: reading waits for the file.
    @State private var journalLines: [String] = []

    private func loadJournalLines() -> [String] {
        viewModel.journal?.reportLines(utcOffsetSeconds: Self.utcOffsetSeconds) ?? []
    }

    var body: some View {
        Form {
            Section(tr("מצב", "Status")) {
                LabeledContent(tr("שלב", "Stage"), value: Self.describe(viewModel.phase))
                LabeledContent(tr("מנוע פעיל", "Active engine"), value: viewModel.pipeline.activeEngineKind?.displayName ?? "—")
                LabeledContent(tr("מודל Whisper", "Whisper model"), value: viewModel.settings.whisperModelVariant)
                LabeledContent(tr("שפה", "Language"), value: viewModel.settings.languageCode)
                if let failure = viewModel.phase.failure {
                    LabeledContent(tr("פרטי תקלה", "Failure details")) {
                        Text(failure.detail)
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                    }
                }
            }

            Section(tr("אודיו", "Audio")) {
                LabeledContent(tr("מיקרופון נבחר", "Selected microphone"), value: viewModel.selectedInput?.portName ?? "—")
                LabeledContent(tr("מיקרופונים זמינים", "Available microphones"), value: "\(viewModel.availableInputs.count)")
                ForEach(viewModel.availableInputs) { input in
                    Text("\(input.portName) · \(MicPickerView.typeName(for: input.portType))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent(tr("עוצמה עכשיו", "Level now"), value: String(format: "%.0f%%", viewModel.inputLevel * 100))
                LabeledContent(tr("חבילות אודיו", "Audio chunks"), value: "\(viewModel.stats.audioChunksReceived)")
                LabeledContent(tr("שניות אודיו", "Audio seconds"), value: String(format: "%.1f", viewModel.stats.audioSecondsReceived))
                LabeledContent(tr("החלפות מיקרופון", "Microphone changes"), value: "\(viewModel.stats.inputChanges)")
                LabeledContent(tr("המיקרופון נתקע", "Microphone stalls"), value: "\(viewModel.stats.audioStalls)")
                LabeledContent(tr("רמות קול (dBFS)", "Sound levels (dBFS)"), value: Self.levelsText(viewModel.stats.inputLevels))
                LabeledContent(tr("נשמע כדיבור", "Sounded like speech"), value: viewModel.stats.speechShare.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                LabeledContent(tr("זיהוי צלילים", "Sound detection"), value: viewModel.stats.soundDetectionRunning ? tr("פועל", "Running") : (viewModel.isListening ? tr("נעצר", "Stopped") : "—"))
            }

            nearMissesSection

            Section(tr("תמלול", "Transcription")) {
                LabeledContent(tr("עדכונים מהמנוע", "Updates from engine"), value: "\(viewModel.stats.tokensReceived)")
                LabeledContent(tr("שורות שנסגרו", "Lines closed"), value: "\(viewModel.stats.segmentsCommitted)")
                LabeledContent(tr("שורות על המסך", "Lines on screen"), value: "\(viewModel.segments.count)")
                LabeledContent(tr("פיגור כתוביות", "Caption lag"), value: viewModel.stats.captionLagSeconds.map { String(format: tr("%.1f שנ׳", "%.1f s"), $0) } ?? "—")
                LabeledContent(tr("הפעלות מחדש", "Restarts"), value: "\(viewModel.stats.engineRestarts)")
                LabeledContent(tr("דוברים שזוהו", "Speakers identified"), value: "\(viewModel.pipeline.speakerClusters.count)")
                LabeledContent(tr("דוברים חדשים בסשן", "New speakers this session"), value: "\(viewModel.stats.speakerClustersOpened)")
                if let started = viewModel.stats.sessionStartedAt {
                    LabeledContent(tr("התחלת סשן", "Session started"), value: Date(timeIntervalSince1970: started).formatted(date: .omitted, time: .standard))
                }
            }

            Section(tr("התאוששות", "Recovery")) {
                LabeledContent(tr("ניסיון חוזר אוטומטי", "Automatic retry"), value: retryText)
                LabeledContent(tr("שיחת טלפון תופסת את האודיו", "Phone call is using the audio"), value: viewModel.isInterruptedBySystem ? tr("כן", "Yes") : tr("לא", "No"))
                LabeledContent(tr("שמירת הגדרות", "Settings save"), value: viewModel.settingsSaveError == nil ? tr("תקינה", "OK") : tr("נכשלה", "Failed"))
                LabeledContent(tr("שמירת שיחות", "Conversation history save"), value: viewModel.historySaveFailure == nil ? tr("תקינה", "OK") : tr("נכשלה", "Failed"))
                LabeledContent(tr("הודעה אחרונה בטלפון", "Last phone notification"), value: AlertNotifier.shared.lastFailure == nil ? tr("תקינה", "OK") : tr("נכשלה", "Failed"))
                LabeledContent(tr("רטט להתראות", "Alert vibration"), value: Self.vibrationText)
                LabeledContent(tr("חיבור לאינטרנט", "Internet connection"), value: Self.describe(viewModel.pipeline.networkConditions))
            }

            Section {
                let lines = viewModel.pipeline.eventLog.reportLines(utcOffsetSeconds: Self.utcOffsetSeconds)
                if lines.isEmpty {
                    Text(tr("עוד לא קרה כלום", "Nothing has happened yet"))
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
                Text(tr("אירועים אחרונים", "Recent events"))
            } footer: {
                Text(tr("החדש ביותר למעלה. הדוח המועתק כולל את כל הרשימה.", "Newest at the top. The copied report includes the full list."))
            }

            Section {
                Button {
                    viewModel.markProblem()
                    journalLines = loadJournalLines()
                } label: {
                    Label(tr("לסמן בעיה עכשיו", "Mark a problem now"), systemImage: "exclamationmark.bubble")
                }
                ForEach(Array(journalLines.suffix(15).reversed().enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .environment(\.layoutDirection, .leftToRight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text(tr("יומן, כולל הפעלות קודמות", "Journal, previous runs included"))
            } footer: {
                Text(tr("נשמר בטלפון גם כשהאפליקציה נסגרת, ונשלח רק עם הדוח. כשמסמנים בעיה נשמרות גם השורות האחרונות של הכתוביות.", "Kept on the phone even when the app closes, and sent only with the report. Marking a problem also keeps the last few caption lines."))
            }

            Section(tr("מודל ומילים", "Model and words")) {
                LabeledContent(tr("מצב המודל", "Model state"), value: Self.describe(modelState))
                LabeledContent(tr("טוקנייזר שמור", "Tokenizer cached"), value: store.hasCachedTokenizer() ? tr("כן", "Yes") : tr("לא (צריך אינטרנט פעם אחת)", "No (needs internet once)"))
                LabeledContent(tr("שמות ומילים", "Names and words"), value: "\(viewModel.vocabulary.count)")
                LabeledContent(tr("התראות מילים", "Word alerts"), value: "\(viewModel.settings.keywordAlerts.filter(\.isEnabled).count)")
            }

            Section(tr("מכשיר", "Device")) {
                LabeledContent(tr("חום", "Temperature"), value: Self.describe(ProcessInfo.processInfo.thermalState))
                LabeledContent(tr("מצב חיסכון בסוללה", "Low power mode"), value: ProcessInfo.processInfo.isLowPowerModeEnabled ? tr("פעיל", "On") : tr("כבוי", "Off"))
                LabeledContent(tr("סוללה", "Battery"), value: Self.batteryText)
                LabeledContent(tr("מקום פנוי", "Free space"), value: Self.freeSpaceText)
                LabeledContent(tr("זיכרון", "Memory"), value: Self.memoryText)
                LabeledContent(tr("דגם", "Model"), value: UIDevice.current.model)
                LabeledContent("iOS", value: UIDevice.current.systemVersion)
                LabeledContent(tr("אפליקציה", "App"), value: SettingsView.versionString)
                LabeledContent(tr("ההתקנה תקפה עד", "Install valid until"), value: Self.installExpiryText)
            }

            Section {
                ShareLink(item: report, subject: Text(tr("דוח אבחון מאוזן", "Ozen diagnostics report"))) {
                    Label(tr("שליחת הדוח", "Send report"), systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.string = report
                    copied = true
                } label: {
                    Label(copied ? tr("הועתק", "Copied") : tr("העתקת הדוח", "Copy report"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
        }
        .task { journalLines = loadJournalLines() }
        .accessibilityIdentifier("diagnosticsScreen")
        .navigationTitle(tr("אבחון", "Diagnostics"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private let store = WhisperModelStore()

    private var modelState: ModelFolderState {
        store.state(of: viewModel.settings.whisperModelVariant)
    }

    private var retryText: String {
        guard let retry = viewModel.pipeline.scheduledRetry else { return "—" }
        let seconds = max(0, Int((retry.at - Date().timeIntervalSince1970).rounded()))
        return tr("ניסיון \(retry.attempt), בעוד \(seconds) שנ׳", "Attempt \(retry.attempt), in \(seconds) s")
    }

    private static var installExpiryText: String {
        guard let date = InstallExpiryStatus.shared.expiresAt else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static var vibrationText: String {
        let player = AlertHapticPlayer.shared
        guard player.supportsHaptics else { return tr("לא נתמך במכשיר", "Not supported on this device") }
        return player.lastFailure == nil ? tr("תקין", "OK") : tr("נכשל, רטט רגיל במקום", "Failed, using standard vibration instead")
    }

    private static var batteryText: String {
        let device = UIDevice.current
        guard device.isBatteryMonitoringEnabled, device.batteryLevel >= 0 else { return "—" }
        let plugged = device.batteryState == .charging || device.batteryState == .full
        return "\(Int((device.batteryLevel * 100).rounded()))%\(plugged ? tr(" · בטעינה", " · charging") : "")"
    }

    private static func format(bytes: Int64) -> String {
        ModelManagerView.format(bytes: bytes)
    }

    private var eventLines: String {
        let lines = viewModel.pipeline.eventLog.reportLines(utcOffsetSeconds: Self.utcOffsetSeconds)
        return lines.isEmpty ? "-" : lines.joined(separator: "\n")
    }

    private var journalText: String {
        journalLines.isEmpty ? "-" : journalLines.joined(separator: "\n")
    }

    private static var utcOffsetSeconds: Int {
        TimeZone.current.secondsFromGMT(for: Date())
    }

    /// "812 MB in use · 1.9 GB more": what the app uses, and how much more
    /// iOS lets it have before ending it.
    private static var memoryText: String {
        var parts: [String] = []
        if let used = DeviceMemory.footprintBytes() { parts.append(tr("\(format(bytes: used)) בשימוש", "\(format(bytes: used)) in use")) }
        if let left = DeviceMemory.availableBytes() { parts.append(tr("עוד \(format(bytes: left))", "\(format(bytes: left)) more")) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private static var freeSpaceText: String {
        guard let bytes = DeviceStorage.availableBytes() else { return "—" }
        return format(bytes: bytes)
    }

    static func describe(_ state: ModelFolderState) -> String {
        switch state {
        case .missing: return tr("לא הורד", "Not downloaded")
        case .partial: return tr("הורדה נקטעה", "Download interrupted")
        case .unverified: return tr("מותקן (לא אומת)", "Installed (unverified)")
        case .verified: return tr("מותקן", "Installed")
        }
    }

    static func describe(_ thermal: ProcessInfo.ThermalState) -> String {
        switch thermal {
        case .nominal: return tr("רגיל", "Normal")
        case .fair: return tr("חמים", "Warm")
        case .serious: return tr("חם · הכתוביות מאטות", "Hot · captions are slowing down")
        case .critical: return tr("חם מאוד · הכתוביות מאטות מאוד", "Very hot · captions are slowing a lot")
        @unknown default: return tr("לא ידוע", "Unknown")
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
        audio chunks: \(stats.audioChunksReceived) seconds: \(String(format: "%.1f", stats.audioSecondsReceived)) input changes: \(stats.inputChanges) stalls: \(stats.audioStalls) damaged: \(stats.glitchedAudioChunks)
        levels: \(stats.inputLevels.summary ?? "-") speech: \(stats.speechShare.map { String(format: "%.1f%%", $0 * 100) } ?? "-") floor: \(stats.noiseFloorDecibels.map { String(format: "%.1f", $0) } ?? "-") margin: \(stats.noiseMarginDecibels.map { String(format: "%.1f dB", $0) } ?? "-")
        tokens: \(stats.tokensReceived) committed: \(stats.segmentsCommitted) on screen: \(viewModel.segments.count) lag: \(stats.captionLagSeconds.map { String(format: "%.2f", $0) } ?? "-")
        restarts: \(stats.engineRestarts) clusters: \(viewModel.pipeline.speakerClusters.count) opened: \(stats.speakerClustersOpened)
        retry: \(viewModel.pipeline.scheduledRetry.map { "attempt \($0.attempt)" } ?? "-") interrupted: \(viewModel.isInterruptedBySystem) sound detection: \(viewModel.stats.soundDetectionRunning)
        sounds heard below the alert level: \(viewModel.pipeline.soundNearMisses.reportLine(utcOffsetSeconds: Self.utcOffsetSeconds) ?? "-")
        alerts: sounds \(viewModel.settings.soundAlerts.isEnabled) from \(viewModel.settings.soundAlerts.minimumImportance) muted \(viewModel.settings.soundAlerts.mutedIdentifiers.count) words on \(viewModel.settings.keywordAlerts.filter(\.isEnabled).count) of \(viewModel.settings.keywordAlerts.count) when away: \(viewModel.settings.notifyWhenInBackground) buzz on speech: \(viewModel.settings.hapticOnSpeechResume)
        history: saving \(viewModel.settings.saveHistory) keep \(viewModel.settings.historyRetention) speakers saved \(viewModel.settings.speakerProfiles.count) separation \(String(format: "%.2f", viewModel.settings.speakerSimilarityThreshold)) display: size \(Int(viewModel.display.fontSize)) theme \(viewModel.display.theme.rawValue) awake \(viewModel.display.keepScreenAwake)
        lock screen: setting \(viewModel.display.lockScreenCaptions) allowed by iOS: \(viewModel.lockScreenCaptionsAllowedBySystem) showing: \(viewModel.lockScreenCaptionsShowing) last refused: \(viewModel.lockScreenCaptionsLastStartFailure ?? "-")
        settings save error: \(viewModel.settingsSaveError ?? "-") history save error: \(viewModel.historySaveFailure ?? "-") notification error: \(AlertNotifier.shared.lastFailure ?? "-") haptics: \(AlertHapticPlayer.shared.supportsHaptics ? (AlertHapticPlayer.shared.lastFailure ?? "ok") : "unsupported") network: \(Self.describe(viewModel.pipeline.networkConditions)) cellular downloads: \(viewModel.allowCellularModelDownload)
        model state: \(String(describing: modelState)) tokenizer cached: \(store.hasCachedTokenizer()) vocabulary: \(viewModel.vocabulary.count)
        thermal: \(ProcessInfo.processInfo.thermalState.rawValue) low power: \(ProcessInfo.processInfo.isLowPowerModeEnabled) battery: \(Self.batteryText) free space: \(Self.freeSpaceText)
        memory: used \(DeviceMemory.footprintBytes().map(Self.format(bytes:)) ?? "-") left \(DeviceMemory.availableBytes().map(Self.format(bytes:)) ?? "-")
        device: \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion) app \(SettingsView.versionString) install expires: \(InstallExpiryStatus.shared.expiresAt.map { String(describing: $0) } ?? "-")
        events (oldest first):
        \(eventLines)
        journal, previous runs included (oldest first):
        \(journalText)
        """
    }

    /// Alert sounds the classifier heard, but not surely enough to alert:
    /// tells "never heard the doorbell" from "heard it faintly".
    @ViewBuilder
    private var nearMissesSection: some View {
        let misses = viewModel.pipeline.soundNearMisses.recentFirst
        if !misses.isEmpty {
            Section {
                ForEach(misses, id: \.identifier) { miss in
                    LabeledContent(
                        SoundEventCatalog.event(for: miss.identifier)?.name ?? miss.identifier,
                        value: "\(Int((miss.bestConfidence * 100).rounded()))% · \(Date(timeIntervalSince1970: miss.lastHeardAt).formatted(date: .omitted, time: .shortened))"
                    )
                }
            } header: {
                Text(tr("צלילים שנשמעו חלש מדי להתראה", "Sounds heard too faint to alert"))
            } footer: {
                Text(tr("התראה צריכה ביטחון של \(Int((viewModel.pipeline.soundAlertConfidence * 100).rounded()))%. צליל שמופיע כאן נשמע, אבל רחוק או חלש מדי.", "An alert needs \(Int((viewModel.pipeline.soundAlertConfidence * 100).rounded()))% confidence. A sound listed here was heard, but too far or too faint."))
            }
        }
    }

    /// The quiet, middle and loud ends of what the microphone heard, in
    /// Hebrew reading order: quiet first.
    static func levelsText(_ levels: AudioLevelHistogram) -> String {
        guard let quiet = levels.decibels(atFraction: 0.1),
              let middle = levels.decibels(atFraction: 0.5),
              let loud = levels.decibels(atFraction: 0.9)
        else { return "—" }
        return tr("שקט \(quiet) · אמצע \(middle) · חזק \(loud)", "quiet \(quiet) · mid \(middle) · loud \(loud)")
    }

    static func describe(_ network: NetworkConditions?) -> String {
        guard let network else { return "—" }
        guard network.isConnected else { return tr("אין חיבור", "No connection") }
        var parts = [network.isExpensive ? tr("סלולרי", "Cellular") : "Wi-Fi"]
        if network.isConstrained { parts.append(tr("חיסכון בנתונים", "Data saving")) }
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
