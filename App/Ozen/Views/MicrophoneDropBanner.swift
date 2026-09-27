import SwiftUI
import OzenKit

struct MicrophoneDropBanner: View {
    let title: String
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
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
                Spacer()
                Image(systemName: "xmark")
                    .font(.headline)
                    .opacity(0.7)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Color.orange.deepShade.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(tr("הקישו לסגירה", "Tap to close"))
        .accessibilityIdentifier("microphoneDropBanner")
    }
}
