import SwiftUI

#if compiler(>=6.2)
extension View {
    @ViewBuilder
    func ozenGlass(in shape: some Shape, interactive: Bool = false, fallback: Material = .ultraThinMaterial) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(fallback, in: shape)
        }
    }

    @ViewBuilder
    func ozenGlassBar() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                .padding(.horizontal, 10)
        } else {
            background(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    func ozenGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}
#else
extension View {
    func ozenGlass(in shape: some Shape, interactive: Bool = false, fallback: Material = .ultraThinMaterial) -> some View {
        background(fallback, in: shape)
    }

    func ozenGlassBar() -> some View {
        background(.ultraThinMaterial)
    }

    @ViewBuilder
    func ozenGlassButton(prominent: Bool = false) -> some View {
        if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}
#endif
