import SwiftUI
import Testing
@testable import Ozen
@testable import OzenKit

struct CaptionThemeResolutionTests {
    @Test("match the phone follows its light or dark setting and leaves the scheme to the system")
    func matchPhone() {
        let light = CaptionTheme(.matchPhone, system: .light)
        #expect(light.background == .white)
        #expect(light.text == .black)
        #expect(light.colorScheme == .light)
        #expect(light.preferredScheme == nil)

        let dark = CaptionTheme(.matchPhone, system: .dark)
        #expect(dark.background == .black)
        #expect(dark.text == .white)
        #expect(dark.preferredScheme == nil)
    }

    @Test("a fixed look ignores the phone's scheme and asks for its own")
    func fixedLooks() {
        #expect(CaptionTheme(.dark, system: .light).background == .black)
        #expect(CaptionTheme(.dark, system: .light).preferredScheme == .dark)
        #expect(CaptionTheme(.light, system: .dark).background == .white)
        #expect(CaptionTheme(.light, system: .dark).preferredScheme == .light)
        #expect(CaptionTheme(.highContrast, system: .light).preferredScheme == .dark)
    }

    @Test("Increase Contrast draws words still being heard as strongly as finished ones, and thickens cards")
    func increasedContrast() {
        for look in DisplayPreferences.Theme.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let standard = CaptionTheme(look, system: scheme, contrast: .standard)
                let increased = CaptionTheme(look, system: scheme, contrast: .increased)
                #expect(standard.pendingText != standard.text)
                #expect(increased.pendingText == increased.text)
                #expect(increased.cardFill > standard.cardFill)
            }
        }
    }
}
