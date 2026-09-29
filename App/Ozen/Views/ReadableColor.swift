import SwiftUI

struct ReadableColor: ShapeStyle {
    let color: Color

    func resolve(in environment: EnvironmentValues) -> Color {
        color.readable(on: environment.colorScheme)
    }
}

extension ShapeStyle where Self == ReadableColor {
    static func readable(_ color: Color) -> ReadableColor {
        ReadableColor(color: color)
    }
}
