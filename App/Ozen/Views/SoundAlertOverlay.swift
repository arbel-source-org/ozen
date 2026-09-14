import SwiftUI
import OzenKit

/// The latest sound alert's banner and screen-edge flash, for screens that
/// cover the caption screen, whose own banner and flash are hidden behind
/// them. Typing a reply or holding up the big-letters pad is exactly when a
/// doorbell would otherwise go unseen.
///
/// Only an alert that arrives while the screen is open shows: opening it
/// never replays one from before.
private struct SoundAlertOverlay: ViewModifier {
    let alert: SoundAlert?
    @State private var shown: SoundAlert?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let shown {
                    SoundAlertBanner(alert: shown) {
                        withAnimation { self.shown = nil }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay {
                AlertFlashOverlay(alert: alert)
            }
            .onChange(of: alert?.id) { _, _ in
                guard let alert else { return }
                withAnimation { shown = alert }
            }
            .task(id: shown?.id) {
                // Same timing as the caption screen's banner.
                guard let current = shown else { return }
                let seconds = current.event.importance == .critical ? 16 : 8
                try? await Task.sleep(for: .seconds(seconds))
                // A cancelled sleep still gets here; only clear the banner
                // this wait was for.
                if shown?.id == current.id {
                    withAnimation { shown = nil }
                }
            }
    }
}

extension View {
    /// Shows sound alerts that arrive while this screen covers the captions.
    func soundAlertOverlay(_ alert: SoundAlert?) -> some View {
        modifier(SoundAlertOverlay(alert: alert))
    }
}
