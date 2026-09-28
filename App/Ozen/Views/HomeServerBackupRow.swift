import SwiftUI
import OzenKit

struct HomeServerBackupRow: View {
    @Bindable var viewModel: LiveCaptionViewModel

    var body: some View {
        let status = viewModel.backupModelStatus
        VStack(alignment: .leading, spacing: 8) {
            switch status {
            case .notNeeded:
                EmptyView()
            case .ready:
                Label(tr("גיבוי בטלפון מוכן: כשאין חיבור למחשב, הטלפון ממשיך לבד.", "Backup on the phone is ready: when the computer can’t be reached, the phone carries on by itself."), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .missing(let megabytes):
                downloadButton(megabytes: megabytes)
                note(tr("בלי הגיבוי, הכתוביות נעצרות כשאין חיבור למחשב.", "Without the backup, captions stop when the computer can’t be reached."))
            case .downloading(let fraction):
                ProgressView(value: fraction) {
                    Text(tr("מוריד את הגיבוי · %1%", "Downloading the backup · %1%", args: ["\(Int((fraction * 100).rounded()))"]))
                }
            case .waitingForWiFi:
                note(tr("הגיבוי יורד רק ב‑Wi‑Fi. התחברו ל‑Wi‑Fi כדי להוריד אותו.", "The backup downloads only on Wi‑Fi. Connect to Wi‑Fi to download it."))
            case .offline:
                note(tr("אין אינטרנט, אז אי אפשר להוריד את הגיבוי עכשיו.", "There’s no internet, so the backup can’t be downloaded now."))
            case .notEnoughRoom(let megabytes):
                Label(tr("אין מספיק מקום בטלפון לגיבוי. צריך לפנות עוד %1.", "Not enough room on the phone for the backup. %1 more needs to be freed up.", args: ["\(PhasePresentation.sizeText(megabytes: megabytes))"]), systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.red)
            case .failed:
                downloadButton(megabytes: nil)
                Label(tr("ההורדה של הגיבוי נעצרה. נסו שוב.", "The backup download stopped. Try again."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityIdentifier("homeServerBackupRow")
    }

    private func downloadButton(megabytes: Int?) -> some View {
        Button {
            viewModel.downloadBackupModel()
        } label: {
            if let megabytes {
                Label(tr("הורדת גיבוי לטלפון (%1)", "Download a backup to the phone (%1)", args: ["\(PhasePresentation.sizeText(megabytes: megabytes))"]), systemImage: "arrow.down.circle")
            } else {
                Label(tr("הורדת גיבוי לטלפון", "Download a backup to the phone"), systemImage: "arrow.down.circle")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
