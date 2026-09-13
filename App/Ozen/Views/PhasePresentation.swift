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
        case retry
        case openSystemSettings
        case openEngineSettings
    }

    let title: String
    let detail: String?
    let systemImage: String
    let tint: Color
    let progress: Double?
    let isBusy: Bool
    let action: Action

    init(phase: PipelinePhase, engine: TranscriptionEngineKind?, interruptedBySystem: Bool) {
        if interruptedBySystem {
            self.init(
                title: "הכתוביות מושהות בגלל שיחה",
                detail: "ימשיכו אוטומטית כשהשיחה תסתיים",
                systemImage: "phone.fill",
                tint: .orange,
                action: .none
            )
            return
        }

        switch phase {
        case .idle:
            self.init(title: "לא פעיל", detail: "הקישו כדי להתחיל", systemImage: "play.circle.fill", tint: .secondary, action: .start)

        case .requestingMicrophonePermission:
            self.init(title: "מבקש גישה למיקרופון", detail: "אשרו בחלון שנפתח", systemImage: "mic.badge.plus", tint: .yellow, isBusy: true)

        case .preparingEngine(let progress):
            self.init(preparation: progress, engine: engine)

        case .startingAudio:
            self.init(title: "מפעיל את המיקרופון", detail: nil, systemImage: "mic", tint: .yellow, isBusy: true)

        case .listening:
            self.init(title: "מקשיב", detail: "הקישו להשהיה", systemImage: "waveform", tint: .green, action: .pause)

        case .paused:
            self.init(title: "מושהה", detail: "הקישו להמשיך", systemImage: "pause.circle.fill", tint: .orange, action: .resume)

        case .failed(let failure):
            self.init(failure: failure, engine: engine)
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

    private init(preparation: EnginePreparationProgress, engine: TranscriptionEngineKind?) {
        let modelName = preparation.detail.flatMap { WhisperModelCatalog.option(for: $0)?.displayName } ?? preparation.detail
        switch preparation.stage {
        case .checkingSupport:
            self.init(title: "בודק את מנוע התמלול", detail: nil, systemImage: "gearshape.2", tint: .yellow, isBusy: true)
        case .requestingPermission:
            self.init(title: "מבקש אישור לזיהוי דיבור", detail: "אשרו בחלון שנפתח", systemImage: "waveform.badge.plus", tint: .yellow, isBusy: true)
        case .downloadingModel:
            let percent = preparation.fraction.map { Int(($0 * 100).rounded()) }
            let title = percent.map { "מוריד את מודל השפה · \($0)%" } ?? "מוריד את מודל השפה"
            let detail = modelName.map { "\($0) · פעם אחת בלבד, דרך Wi-Fi" } ?? "פעם אחת בלבד, דרך Wi-Fi"
            self.init(title: title, detail: detail, systemImage: "arrow.down.circle", tint: .yellow, progress: preparation.fraction, isBusy: true)
        case .loadingModel:
            self.init(title: "טוען את המודל", detail: "בפעם הראשונה זה יכול לקחת דקה או שתיים", systemImage: "cpu", tint: .yellow, isBusy: true)
        case .warmingUp:
            self.init(title: "כמעט מוכן", detail: nil, systemImage: "flame", tint: .yellow, isBusy: true)
        }
    }

    private init(failure: PipelineFailure, engine: TranscriptionEngineKind?) {
        switch failure.kind {
        case .microphonePermissionDenied:
            self.init(
                title: "אין גישה למיקרופון",
                detail: "הקישו כדי לפתוח את הגדרות המכשיר ולאפשר",
                systemImage: "mic.slash",
                tint: .red,
                action: .openSystemSettings
            )

        case .audioSessionFailed:
            self.init(title: "המיקרופון לא מגיב", detail: "הקישו לנסות שוב", systemImage: "exclamationmark.triangle", tint: .red, action: .retry)

        case .noAudioInputs:
            self.init(title: "לא נמצא מיקרופון", detail: "הקישו לנסות שוב", systemImage: "mic.slash", tint: .red, action: .retry)

        case .transcriptionStopped:
            self.init(title: "התמלול נעצר", detail: "הקישו כדי להמשיך", systemImage: "exclamationmark.triangle", tint: .orange, action: .retry)

        case .engineUnavailable:
            self.init(engineFailure: failure.engineUnavailability, engine: engine)
        }
    }

    private init(engineFailure: EngineUnavailability?, engine: TranscriptionEngineKind?) {
        let engineName = engine == .appleSpeech ? "זיהוי הדיבור של אפל" : "Whisper"
        switch engineFailure?.kind {
        case .permissionDenied:
            self.init(
                title: "אין אישור לזיהוי דיבור",
                detail: "הקישו כדי לפתוח את הגדרות המכשיר ולאפשר",
                systemImage: "waveform.slash",
                tint: .red,
                action: .openSystemSettings
            )
        case .languageNotSupportedOnDevice:
            self.init(
                title: "\(engineName) לא זמין בעברית במכשיר הזה",
                detail: "הקישו כדי לעבור למנוע אחר בהגדרות",
                systemImage: "globe",
                tint: .red,
                action: .openEngineSettings
            )
        case .modelDownloadFailed:
            self.init(
                title: "הורדת המודל נכשלה",
                detail: "בדקו חיבור לאינטרנט והקישו לנסות שוב",
                systemImage: "wifi.exclamationmark",
                tint: .red,
                action: .retry
            )
        case .modelLoadFailed:
            self.init(
                title: "טעינת המודל נכשלה",
                detail: "הקישו לנסות שוב, או בחרו מודל קטן יותר בהגדרות",
                systemImage: "cpu",
                tint: .red,
                action: .retry
            )
        case .temporarilyUnavailable:
            self.init(title: "\(engineName) לא זמין כרגע", detail: "הקישו לנסות שוב", systemImage: "clock", tint: .orange, action: .retry)
        case .other, .none:
            self.init(title: "\(engineName) לא זמין", detail: "הקישו לנסות שוב", systemImage: "exclamationmark.triangle", tint: .red, action: .retry)
        }
    }
}
