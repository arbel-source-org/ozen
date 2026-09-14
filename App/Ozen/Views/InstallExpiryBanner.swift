import SwiftUI
import OzenKit

/// "Ozen stops opening tomorrow at 07:24" in the caption screen's top
/// overlay, in the last two days of a free Apple ID install (see
/// `InstallExpiry`). Tapping hides it until the app next comes back on
/// screen.
struct InstallExpiryBanner: View {
    let expiresAt: Date
    /// Keeps "today"/"tomorrow" right when the screen stays open overnight.
    let now: Date
    let onDismiss: () -> Void

    private var title: String {
        InstallExpiry.warningTitle(expiresAt: expiresAt, now: now, utcOffsetSeconds: TimeZone.current.secondsFromGMT(for: expiresAt))
    }

    var body: some View {
        Button(action: onDismiss) {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 26, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(InstallExpiry.warningDetail)
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
            .background(Color.purple.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("הקישו לסגירה")
    }
}
