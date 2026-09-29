import SwiftUI
import OzenKit

extension AnyTransition {
    static func banner(from edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }
}

private struct AlertOverlay: ViewModifier {
    let viewModel: LiveCaptionViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: SoundAlert?
    @State private var shownHit: KeywordHit?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if shown != nil || shownHit != nil {
                    VStack(spacing: 8) {
                        if let shown {
                            SoundAlertBanner(alert: shown) {
                                withAnimation { self.shown = nil }
                                viewModel.dismissSoundAlert(id: shown.id)
                            }
                            .transition(.banner(from: .top, reduceMotion: reduceMotion))
                        }
                        if let shownHit {
                            KeywordHitPill(hit: shownHit, speakerName: viewModel.speakerName(for: shownHit))
                                .transition(.banner(from: .top, reduceMotion: reduceMotion))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .overlay {
                AlertFlashOverlay(alert: viewModel.currentScreenSoundAlert)
            }
            .onChange(of: viewModel.screenSoundAlert?.id) { _, _ in
                guard let alert = viewModel.currentScreenSoundAlert, alert.takesBanner(from: shown) else { return }
                withAnimation { shown = alert }
            }
            .onChange(of: viewModel.attentionKeywordHit?.id) { _, _ in
                guard let hit = viewModel.attentionKeywordHit else { return }
                withAnimation { shownHit = hit }
            }
            .task(id: shown?.id) {
                guard let current = shown else { return }
                try? await Task.sleep(for: .seconds(viewModel.bannerSecondsLeft(for: current)))
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
