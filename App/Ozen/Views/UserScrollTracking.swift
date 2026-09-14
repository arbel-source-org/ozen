import SwiftUI

extension View {
    func onUserScroll(_ action: @escaping (_ isScrolling: Bool) -> Void) -> some View {
        modifier(UserScrollTracking(action: action))
    }
}

private struct UserScrollTracking: ViewModifier {
    let action: (_ isScrolling: Bool) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    action(true)
                case .idle, .animating:
                    action(false)
                @unknown default:
                    action(false)
                }
            }
        } else {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 8).onChanged { _ in
                    action(true)
                    action(false)
                }
            )
        }
    }
}
