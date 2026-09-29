import SwiftUI
import UIKit

extension View {
    func announcing(_ text: String, whenTurningTrue condition: Bool, alsoWhenFirstShown: Bool = false) -> some View {
        onChange(of: condition, initial: alsoWhenFirstShown) { _, isTrue in
            guard isTrue else { return }
            let announcement = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }
    }
}
