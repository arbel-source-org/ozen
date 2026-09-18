import SwiftUI
import OzenKit

/// Turns the pipeline's structured state into what the status control
/// shows: a short Hebrew title, an optional second line saying what to do
/// about it, an icon, a colour, and a progress value when one exists. The
/// pipeline itself never produces user-facing text — every string lives
/// here, in one place, so the whole app's status vocabulary can be read
/// (and translated) top to bottom.
struct PhasePresentation {
    enum Action {
        case none
        case start
        case pause
        case resume
        /// Cut the phone off mid-phrase; captions then come back by themselves.
        case stopSpeaking
        case retry
        case openSystemSettings
        case openEngineSettings
        /// Ask before downloading the model over cellular data.
        case confirmCellularDownload
    }

    let title: String
    let detail: String?
    let systemImage: String
    let tint: Color
    let progress: Double?
    let isBusy: Bool
    let action: Action

    init(
        phase: PipelinePhase,
        engine: TranscriptionEngineKind?,
        interruptedBySystem: Bool,
        scheduledRetry: ScheduledRetry? = nil,
        downloadSecondsRemaining: Double? = nil,
        pausedForSpeech: Bool = false
    ) {
        if interruptedBySystem {
            self.init(
                title: tr("הכתוביות מושהות בגלל שיחה", "Captions paused for a call"),
                detail: tr("ימשיכו אוטומטית כשהשיחה תסתיים", "They’ll continue on their own when the call ends"),
                systemImage: "phone.fill",
                tint: .orange,
                action: .none
            )
            return
        }

        switch phase {
        case .idle:
            self.init(title: tr("לא פעיל", "Not active"), detail: tr("הקישו כדי להתחיל", "Tap to start"), systemImage: "play.circle.fill", tint: .secondary, action: .start)

        case .requestingMicrophonePermission:
            self.init(title: tr("מבקש גישה למיקרופון", "Asking for microphone access"), detail: tr("אשרו בחלון שנפתח", "Allow it in the window that opens"), systemImage: "mic.badge.plus", tint: .yellow, isBusy: true)

        case .preparingEngine(let progress):
            self.init(preparation: progress, engine: engine, secondsRemaining: downloadSecondsRemaining)

        case .startingAudio:
            self.init(title: tr("מפעיל את המיקרופון", "Starting the microphone"), detail: nil, systemImage: "mic", tint: .yellow, isBusy: true)

        case .listening:
            self.init(title: tr("מקשיב", "Listening"), detail: tr("הקישו להשהיה", "Tap to pause"), systemImage: "waveform", tint: .green, action: .pause)

        case .paused where pausedForSpeech:
            // Not "paused": that reads as something to fix, and tapping it
            // would open the microphone onto the phone's own voice.
            self.init(title: tr("הטלפון מדבר", "The phone is talking"), detail: tr("הכתוביות ימשיכו לבד כשיסיים · הקישו כדי לעצור אותו", "Captions will continue on their own when it finishes · Tap to stop it"), systemImage: "speaker.wave.2.fill", tint: .orange, action: .stopSpeaking)

        case .paused:
            self.init(title: tr("מושהה", "Paused"), detail: tr("הקישו להמשיך", "Tap to continue"), systemImage: "pause.circle.fill", tint: .orange, action: .resume)

        case .failed(let failure):
            self.init(failure: failure, engine: engine)
            if scheduledRetry != nil {
                // The pipeline is already on it. Say so, calmly, and keep
                // the tap as "try right now" rather than the only way out.
                self = PhasePresentation(
                    title: title,
                    detail: tr("מנסה שוב לבד · הקישו כדי לנסות עכשיו", "Trying again on its own · Tap to try now"),
                    systemImage: "arrow.clockwise",
                    tint: .orange,
                    isBusy: true,
                    action: .retry
                )
            }
        }
    }

    private init(
        title: String,
        detail: String?,
        systemImage: String,
        tint: Color,
        progress: Double? = nil,
        isBusy: Bool = false,
        action: Action = .none
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.tint = tint
        self.progress = progress
        self.isBusy = isBusy
        self.action = action
    }

    private init(preparation: EnginePreparationProgress, engine: TranscriptionEngineKind?, secondsRemaining: Double?) {
        let modelName = preparation.detail.flatMap { WhisperModelCatalog.option(for: $0)?.displayName } ?? preparation.detail
        switch preparation.stage {
        case .checkingSupport:
            self.init(title: tr("בודק את מנוע התמלול", "Checking the transcription engine"), detail: nil, systemImage: "gearshape.2", tint: .yellow, isBusy: true)
        case .requestingPermission:
            self.init(title: tr("מבקש אישור לזיהוי דיבור", "Asking for speech recognition permission"), detail: tr("אשרו בחלון שנפתח", "Allow it in the window that opens"), systemImage: "waveform.badge.plus", tint: .yellow, isBusy: true)
        case .downloadingModel:
            let percent = preparation.fraction.map { Int(($0 * 100).rounded()) }
            let title = percent.map { tr("מוריד את מודל השפה · \($0)%", "Downloading the language model · \($0)%") } ?? tr("מוריד את מודל השפה", "Downloading the language model")
            // The download only runs while the app is open; the screen is
            // kept on meanwhile, but she might still switch away.
            let detail = [secondsRemaining.map(Self.remainingText), modelName, tr("פעם אחת בלבד", "Just this once"), tr("השאירו את האפליקציה פתוחה", "Leave the app open")]
                .compactMap { $0 }
                .joined(separator: " · ")
            self.init(title: title, detail: detail, systemImage: "arrow.down.circle", tint: .yellow, progress: preparation.fraction, isBusy: true)
        case .loadingModel where preparation.isFirstTime:
            self.init(title: tr("מתאים את המודל לטלפון הזה", "Setting the model up for this phone"), detail: tr("פעם אחת בלבד · כמה דקות · השאירו את האפליקציה פתוחה", "Just this once · a few minutes · Leave the app open"), systemImage: "cpu", tint: .yellow, isBusy: true)
        case .loadingModel:
            self.init(title: tr("טוען את המודל", "Loading the model"), detail: tr("רק רגע", "Just a moment"), systemImage: "cpu", tint: .yellow, isBusy: true)
        case .warmingUp:
            self.init(title: tr("כמעט מוכן", "Almost ready"), detail: nil, systemImage: "flame", tint: .yellow, isBusy: true)
        }
    }

    private init(failure: PipelineFailure, engine: TranscriptionEngineKind?) {
        switch failure.kind {
        case .microphonePermissionDenied:
            self.init(
                title: tr("אין גישה למיקרופון", "No microphone access"),
                detail: tr("הקישו כדי לפתוח את הגדרות המכשיר ולאפשר", "Tap to open device settings and allow it"),
                systemImage: "mic.slash",
                tint: .red,
                action: .openSystemSettings
            )

        case .audioSessionFailed:
            self.init(title: tr("המיקרופון לא מגיב", "The microphone isn’t responding"), detail: tr("הקישו לנסות שוב", "Tap to try again"), systemImage: "exclamationmark.triangle", tint: .red, action: .retry)

        case .noAudioInputs:
            self.init(title: tr("לא נמצא מיקרופון", "No microphone found"), detail: tr("הקישו לנסות שוב", "Tap to try again"), systemImage: "mic.slash", tint: .red, action: .retry)

        case .transcriptionStopped:
            self.init(title: tr("התמלול נעצר", "Transcription stopped"), detail: tr("הקישו כדי להמשיך", "Tap to continue"), systemImage: "exclamationmark.triangle", tint: .orange, action: .retry)

        case .engineUnavailable:
            self.init(engineFailure: failure.engineUnavailability, engine: engine)
        }
    }

    private init(engineFailure: EngineUnavailability?, engine: TranscriptionEngineKind?) {
        let engineName: String
        switch engine {
        case .appleSpeech: engineName = tr("זיהוי הדיבור של אפל", "Apple’s speech recognition")
        case .cloud: engineName = tr("התמלול בענן", "Cloud transcription")
        case .whisperKit, .none: engineName = "Whisper"
        }
        switch engineFailure?.kind {
        case .permissionDenied:
            self.init(
                title: tr("אין אישור לזיהוי דיבור", "No speech recognition permission"),
                detail: tr("הקישו כדי לפתוח את הגדרות המכשיר ולאפשר", "Tap to open device settings and allow it"),
                systemImage: "waveform.slash",
                tint: .red,
                action: .openSystemSettings
            )
        case .languageNotSupportedOnDevice:
            self.init(
                title: tr("\(engineName) לא זמין בעברית במכשיר הזה", "\(engineName) isn’t available in Hebrew on this device"),
                detail: tr("הקישו כדי לעבור למנוע אחר בהגדרות", "Tap to switch engines in Settings"),
                systemImage: "globe",
                tint: .red,
                action: .openEngineSettings
            )
        case .modelDownloadFailed:
            self.init(
                title: tr("הורדת המודל נכשלה", "Downloading the model failed"),
                detail: tr("בדקו חיבור לאינטרנט והקישו לנסות שוב", "Check the internet connection and tap to try again"),
                systemImage: "wifi.exclamationmark",
                tint: .red,
                action: .retry
            )
        case .waitingForWiFi:
            let size = engineFailure?.downloadMegabytes.flatMap { $0 > 0 ? "\($0) MB" : nil }
            self.init(
                title: tr("ממתין ל-Wi-Fi כדי להוריד את מודל השפה", "Waiting for Wi‑Fi to download the language model"),
                detail: [size, tr("יורד לבד כשיהיה Wi-Fi · הקישו להורדה עכשיו", "Downloads on its own once there’s Wi‑Fi · Tap to download now")].compactMap { $0 }.joined(separator: " · "),
                systemImage: "wifi",
                tint: .orange,
                action: .confirmCellularDownload
            )
        case .notEnoughStorage:
            let missing = engineFailure?.missingMegabytes.flatMap { $0 > 0 ? tr("צריך לפנות עוד \(Self.sizeText(megabytes: $0))", "Need to free up \(Self.sizeText(megabytes: $0)) more") : nil }
            self.init(
                title: tr("אין מספיק מקום פנוי בטלפון", "Not enough free space on the phone"),
                detail: [missing, tr("או הקישו לבחור מודל קטן יותר", "Or tap to choose a smaller model")].compactMap { $0 }.joined(separator: " · "),
                systemImage: "externaldrive.badge.exclamationmark",
                tint: .red,
                action: .openEngineSettings
            )
        case .modelLoadFailed:
            self.init(
                title: tr("טעינת המודל נכשלה", "Loading the model failed"),
                detail: tr("הקישו לנסות שוב, או בחרו מודל קטן יותר בהגדרות", "Tap to try again, or choose a smaller model in Settings"),
                systemImage: "cpu",
                tint: .red,
                action: .retry
            )
        case .cloudKeyNeeded:
            self.init(
                title: tr("התמלול בענן צריך מפתח OpenRouter תקין", "Cloud transcription needs a valid OpenRouter key"),
                detail: tr("הקישו כדי להזין מפתח בהגדרות", "Tap to enter a key in Settings"),
                systemImage: "key",
                tint: .orange,
                action: .openEngineSettings
            )
        case .cloudOutOfCredit:
            self.init(
                title: tr("נגמר הקרדיט של מפתח OpenRouter", "The OpenRouter key’s credit ran out"),
                detail: tr("הוסיפו קרדיט באתר OpenRouter, או הקישו לעבור ל‑Whisper שבטלפון", "Add credit on the OpenRouter site, or tap to switch to Whisper on the phone"),
                systemImage: "creditcard",
                tint: .orange,
                action: .openEngineSettings
            )
        case .noInternet:
            self.init(
                title: tr("אין חיבור לאינטרנט", "No internet connection"),
                detail: tr("התמלול בענן צריך אינטרנט · הקישו לנסות שוב", "Cloud transcription needs the internet · Tap to try again"),
                systemImage: "wifi.slash",
                tint: .orange,
                action: .retry
            )
        case .temporarilyUnavailable:
            self.init(title: tr("\(engineName) לא זמין כרגע", "\(engineName) isn’t available right now"), detail: tr("הקישו לנסות שוב", "Tap to try again"), systemImage: "clock", tint: .orange, action: .retry)
        case .other, .none:
            self.init(title: tr("\(engineName) לא זמין", "\(engineName) isn’t available"), detail: tr("הקישו לנסות שוב", "Tap to try again"), systemImage: "exclamationmark.triangle", tint: .red, action: .retry)
        }
    }

    /// "450 MB", or "1.3 GB" once it's that big, in the same decimal
    /// units as the model list and the Settings app. Rounded up: this is
    /// how much room to free, and freeing a little less wouldn't do.
    /// How long a download has left, in words and never falsely precise.
    static func remainingText(seconds: Double) -> String {
        switch seconds {
        case ..<60: return tr("עוד פחות מדקה", "Less than a minute left")
        case ..<90: return tr("עוד כדקה", "About a minute left")
        case ..<(59.5 * 60):
            let minutes = Int((seconds / 60).rounded())
            return minutes == 2 ? tr("עוד כשתי דקות", "About 2 minutes left") : tr("עוד כ-\(minutes) דקות", "About \(minutes) minutes left")
        default: return tr("עוד יותר משעה", "More than an hour left")
        }
    }

    static func sizeText(megabytes: Int) -> String {
        guard megabytes >= 1_000 else { return "\(megabytes) MB" }
        let tenths = (megabytes + 99) / 100
        return "\(tenths / 10).\(tenths % 10) GB"
    }
}
