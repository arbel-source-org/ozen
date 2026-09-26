import SwiftUI
import OzenKit

struct HomeServerGuideView: View {
    struct Step: Identifiable {
        let id: Int
        let systemImage: String
        let title: String
        let text: String
    }

    static var steps: [Step] { [
        Step(
            id: 1, systemImage: "desktopcomputer",
            title: tr("מחשב מתאים", "A suitable computer"),
            text: tr("מחשב Windows בבית עם כרטיס מסך של NVIDIA, עם 6GB זיכרון לפחות (8GB ומעלה למדויק יותר). הוא צריך להישאר דלוק כשרוצים כתוביות ממנו.", "A Windows computer at home with an NVIDIA graphics card of at least 6 GB (8 GB or more for the more accurate captions). It has to be on when captions should come from it.")
        ),
        Step(
            id: 2, systemImage: "arrow.down.circle",
            title: tr("להוריד במחשב את קובץ ההתקנה", "Download the setup file on the computer"),
            text: tr("שלחו לעצמכם את הקישור שלמטה (בדוא״ל או בוואטסאפ) ופתחו אותו במחשב. יורד קובץ אחד.", "Send yourself the link below (by email or WhatsApp) and open it on the computer. One file downloads.")
        ),
        Step(
            id: 3, systemImage: "hand.tap",
            title: tr("ללחוץ עליו פעמיים ולענות על השאלות", "Double-click it and answer its questions"),
            text: tr("הוא בודק קודם שכרטיס המסך מתאים, ומתקין הכול לבד (10 עד 30 דקות). אם Windows שואל אם לאפשר, עונים כן. הוא ישאל אם להשתמש במחשב גם מחוץ לבית.", "It first checks that the graphics card is good enough, then installs everything by itself (10 to 30 minutes). If Windows asks whether to allow it, say yes. It asks whether to use the computer away from home too.")
        ),
        Step(
            id: 4, systemImage: "qrcode.viewfinder",
            title: tr("לסרוק את הריבוע במצלמת האייפון", "Scan the square code with the iPhone camera"),
            text: tr("בסוף מופיע במחשב ריבוע שחור־לבן. פותחים את המצלמה באייפון, מכוונים אליו, לוחצים על הקישור של Ozen ומאשרים. אפשר להציג אותו שוב מתפריט התחל: ״Ozen - pair a phone״.", "At the end the computer shows a black-and-white square. Open the Camera on the iPhone, point it at the square, tap the Ozen link and confirm. To show it again: Start menu, “Ozen - pair a phone”.")
        ),
    ] }

    var body: some View {
        List {
            Section {
                ForEach(Self.steps) { step in
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(step.id). \(step.title)").font(.headline)
                            Text(step.text).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: step.systemImage)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Section {
                ShareLink(item: HomeServer.setupDownload) {
                    Label(tr("שליחת קישור ההורדה", "Send the download link"), systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("shareSetupLink")
                Text(HomeServer.setupDownload.absoluteString)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } footer: {
                Text(tr("כשהמחשב כבוי או רחוק, הטלפון ממשיך לכתוב כתוביות לבד, וחוזר למחשב כשהוא עונה שוב.", "When the computer is off or out of reach, the phone keeps writing captions by itself, and goes back to the computer once it answers again."))
            }
        }
        .navigationTitle(tr("הכנת המחשב בבית", "Setting up the home computer"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("homeServerGuideScreen")
    }
}
