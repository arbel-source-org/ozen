import Testing
@testable import OzenKit

@Suite("ContrastRatio")
struct ContrastRatioTests {
    private let white = (red: 1.0, green: 1.0, blue: 1.0)
    private let black = (red: 0.0, green: 0.0, blue: 0.0)

    @Test("white on black, and black on white, are both the maximum, 21:1")
    func maximum() {
        #expect(abs(ContrastRatio.between(white, black) - 21) < 0.01)
        #expect(abs(ContrastRatio.between(black, white) - 21) < 0.01)
    }

    @Test("the same colour twice has no contrast at all")
    func none() {
        #expect(ContrastRatio.between(white, white) == 1)
        #expect(ContrastRatio.between((red: 0.4, green: 0.2, blue: 0.6), (red: 0.4, green: 0.2, blue: 0.6)) == 1)
    }

    @Test("a translucent colour's contrast is worked out against what it's drawn over")
    func alphaBlend() {
        // Half-opacity white over black draws the same pixel as solid gray.
        let blended = ContrastRatio.ratio(foreground: white, alpha: 0.5, overBackground: black)
        let solid = ContrastRatio.between((red: 0.5, green: 0.5, blue: 0.5), black)
        #expect(abs(blended - solid) < 0.0001)
    }

    @Test("a more opaque foreground contrasts more with its background")
    func moreOpaqueIsHigherContrast() {
        let dim = ContrastRatio.ratio(foreground: white, alpha: 0.5, overBackground: black)
        let bright = ContrastRatio.ratio(foreground: white, alpha: 0.8, overBackground: black)
        #expect(bright > dim)
    }
}
