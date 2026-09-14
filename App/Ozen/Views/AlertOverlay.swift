import SwiftUI
import OzenKit

private struct AlertOverlay: ViewModifier {
    let viewModel: LiveCaptionViewModel
    @State private var shown: SoundAlert?
    @State private var shownHit: KeywordHit?

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
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
                guard let alert = viewModel.soundAlerts.last, alert.takesBanner(from: shown) else { return }
                withAnimation { shown = alert }
            }
            .onChange(of: viewModel.attentionKeywordHit?.id) { _, _ in
                guard let hit = viewModel.attentionKeywordHit else { return }
                withAnimation { shownHit = hit }
            }
            .task(id: shown?.id) {
                guard let current = shown else { return }
                let seconds = current.event.importance == .critical ? 16 : 8
                try? await Task.sleep(for: .seconds(seconds))
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
    func alertOverlay(for viewModel: LiveCaptionViewModel) -> some View {
        modifier(AlertOverlay(viewModel: viewModel))
    }
}
