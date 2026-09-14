import SwiftUI

#if compiler(>=6.2)
extension View {
    @ViewBuilder
    func ozenGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    @ViewBuilder
    func ozenGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
#else
extension View {
    func ozenGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        background(.ultraThinMaterial, in: shape)
    }

    func ozenGlassButton() -> some View {
        buttonStyle(.bordered)
    }
}
#endif
