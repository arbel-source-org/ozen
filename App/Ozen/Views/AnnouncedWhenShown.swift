import SwiftUI
import UIKit

extension View {
    func announcing(_ text: String, whenTurningTrue condition: Bool) -> some View {
        onChange(of: condition) { _, isTrue in
            guard isTrue else { return }
            let announcement = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }
    }
}
