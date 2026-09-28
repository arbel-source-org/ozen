import CoreImage.CIFilterBuiltins
import OzenKit
import SwiftUI
import UIKit

struct SupportOzenView: View {
    @State private var copied: String?

    var body: some View {
        List {
            Section {
                Text(tr("אוזן חינמית ותישאר חינמית, בלי פרסומות ובלי שום דבר נעול. תרומה היא לגמרי לפי רצונכם: אל תרגישו שום מחויבות, ותרמו רק אם המצב הכלכלי שלכם מאפשר זאת בנוחות. עצם השימוש באוזן והמלצה עליה לאחרים כבר עוזרים מאוד.", "Ozen is free and will stay free, with no ads and nothing locked. Donating is entirely up to you: please never feel obligated, and only donate if you’re in a financial position where you can comfortably afford it. Using Ozen and telling others about it already helps a lot."))
            }
            Section {
                Text(tr("1. פתחו את אפליקציית ארנק הקריפטו שלכם ובחרו ״שליחה״.", "1. Open your crypto wallet app and choose Send."))
                Text(tr("2. בחרו את אותו מטבע שמופיע כאן. מטבע שנשלח לכתובת של מטבע אחר הולך לאיבוד.", "2. Pick the same coin as shown here. A coin sent to another coin’s address is lost."))
                Text(tr("3. סרקו את הקוד עם הארנק, או העתיקו את הכתובת והדביקו אותה.", "3. Scan the code with the wallet, or copy the address and paste it."))
                Text(tr("4. לפני השליחה, ודאו שהתווים הראשונים והאחרונים של הכתובת זהים.", "4. Before sending, check that the first and last few characters of the address match."))
            } header: {
                Text(tr("איך תורמים", "How to donate"))
            }
            ForEach(SupportOzen.addresses) { donation in
                Section {
                    addressRow(donation)
                } header: {
                    Text(donation.coin)
                } footer: {
                    if donation == SupportOzen.ethereum {
                        Text(tr("רשת את׳ריום בלבד. אפשר לשלוח גם USDC ו־USDT ברשת את׳ריום.", "Ethereum network only. USDC and USDT on Ethereum are welcome too."))
                    }
                }
            }
        }
        .navigationTitle(tr("תמיכה באוזן", "Support Ozen"))
    }

    private func addressRow(_ donation: DonationAddress) -> some View {
        VStack(spacing: 12) {
            if let code = Self.qrCode(donation.paymentURI) {
                Image(uiImage: code)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
            }
            Text(donation.address)
                .font(.callout.monospaced())
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .environment(\.layoutDirection, .leftToRight)
            Button {
                UIPasteboard.general.string = donation.address
                copied = donation.id
            } label: {
                Label(
                    copied == donation.id ? tr("הועתק", "Copied") : tr("העתקת הכתובת", "Copy address"),
                    systemImage: copied == donation.id ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private static func qrCode(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
