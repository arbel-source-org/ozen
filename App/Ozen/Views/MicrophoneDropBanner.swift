import SwiftUI
import OzenKit

struct MicrophoneDropBanner: View {
    let title: String
    let onChooseMicrophone: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onChooseMicrophone) {
                HStack(spacing: 12) {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 26, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                        Text(MicrophoneDropNotice.detail)
                            .font(.subheadline)
                            .opacity(0.9)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(tr("הקישו כדי לבחור מיקרופון", "Tap to choose a microphone"))
            .accessibilityIdentifier("microphoneDropBanner")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.headline)
                    .opacity(0.8)
                    .frame(minWidth: 44, minHeight: 44)
                    .padding(.trailing, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("סגירה", "Close"))
            .accessibilityIdentifier("microphoneDropBannerClose")
        }
        .frame(maxWidth: .infinity)
        .background(Color.orange.deepShade.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }
}
