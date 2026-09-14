import SwiftUI
import OzenKit

/// The latest sound alert's banner and screen-edge flash, and the pill for
/// her name, for screens that cover the caption screen, whose own are
/// hidden behind them. Typing a reply or holding up the big-letters pad is
/// exactly when a doorbell or her name would otherwise go unseen.
///
/// Only what arrives while the screen is open shows: opening it never
/// replays an older alert.
private struct AlertOverlay: ViewModifier {
    /// Read here, in this modifier's own body, so it redraws when an alert
    /// arrives rather than depending on the presenting screen to.
    let viewModel: LiveCaptionViewModel
    @State private var shown: SoundAlert?
    @State private var shownHit: KeywordHit?

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                // Pushes the screen down rather than covering it: drawn on
                // top, the banner would sit right over a sheet's Close
                // button. Nothing at all when there's nothing to show.
                if shown != nil || shownHit != nil {
                    VStack(spacing: 8) {
                        if let shown {
                            SoundAlertBanner(alert: shown) {
                                withAnimation { self.shown = nil }
                            }
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        if let shownHit {
                            KeywordHitPill(hit: shownHit)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .overlay {
                AlertFlashOverlay(alert: viewModel.soundAlerts.last)
            }
            .onChange(of: viewModel.soundAlerts.last?.id) { _, _ in
                guard let alert = viewModel.soundAlerts.last else { return }
                withAnimation { shown = alert }
            }
            .onChange(of: viewModel.attentionKeywordHit?.id) { _, _ in
                guard let hit = viewModel.attentionKeywordHit else { return }
                withAnimation { shownHit = hit }
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
            .task(id: shownHit?.id) {
                guard let current = shownHit else { return }
                try? await Task.sleep(for: .seconds(5))
                if shownHit?.id == current.id {
                    withAnimation { shownHit = nil }
                }
            }
    }
}

extension View {
    /// Shows sound alerts and her name when they arrive while this screen
    /// covers the captions.
    func alertOverlay(for viewModel: LiveCaptionViewModel) -> some View {
        modifier(AlertOverlay(viewModel: viewModel))
    }
}
