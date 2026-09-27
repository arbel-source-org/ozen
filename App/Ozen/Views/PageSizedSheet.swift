import SwiftUI

extension View {
    @ViewBuilder
    func pageSized() -> some View {
        if #available(iOS 18.0, *) {
            presentationSizing(.page)
        } else {
            self
        }
    }
}
