import SwiftUI
import OzenKit

private struct SoundBannerHandBack: ViewModifier {
    let isCovered: Bool
    let viewModel: LiveCaptionViewModel
    @Binding var banner: SoundAlert?

    func body(content: Content) -> some View {
        content.onChange(of: isCovered) { _, covered in
            guard !covered, let alert = viewModel.screenSoundAlert,
                  viewModel.soundAlerts.contains(where: { $0.id == alert.id }),
                  viewModel.bannerSecondsLeft(for: alert) > 1,
                  alert.takesBanner(from: banner)
            else { return }
            withAnimation { banner = alert }
        }
    }
}

extension View {
    func handsBackSoundBanner(afterCovering isCovered: Bool, viewModel: LiveCaptionViewModel, banner: Binding<SoundAlert?>) -> some View {
        modifier(SoundBannerHandBack(isCovered: isCovered, viewModel: viewModel, banner: banner))
    }
}
