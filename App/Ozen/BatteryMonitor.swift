import UIKit
import Observation
import OzenKit

/// Watches the battery while captions run and raises `BatteryAdvisor`'s
/// warnings for the caption screen to show.
@MainActor
@Observable
final class BatteryMonitor {
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let warning: BatteryWarning
    }

    private(set) var notice: Notice?
    private var advisor = BatteryAdvisor()
    private var observers: [NSObjectProtocol] = []
    private var isActive = false

    /// Starts or stops watching. Readings only count while captions are
    /// running: a warning for a phone that isn't doing anything is noise.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        let device = UIDevice.current
        if active {
            device.isBatteryMonitoringEnabled = true
            let center = NotificationCenter.default
            for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.read() }
                })
            }
            read()
        } else {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            device.isBatteryMonitoringEnabled = false
        }
    }

    func dismiss() {
        notice = nil
    }

    private func read() {
        let device = UIDevice.current
        let pluggedIn = device.batteryState == .charging || device.batteryState == .full
        let level: Float? = device.batteryState == .unknown ? nil : device.batteryLevel
        if pluggedIn {
            notice = nil
        }
        if let warning = advisor.update(level: level, isPluggedIn: pluggedIn) {
            notice = Notice(warning: warning)
        }
    }
}

/// "The battery is at 18%" in the top overlay, tinted by urgency.
struct BatteryBanner: View {
    let notice: BatteryMonitor.Notice
    let onDismiss: () -> Void

    private var isCritical: Bool {
        if case .critical = notice.warning { return true }
        return false
    }

    var body: some View {
        Button(action: onDismiss) {
            HStack(spacing: 12) {
                Image(systemName: isCritical ? "battery.0percent" : "battery.25percent")
                    .font(.system(size: 26, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("הסוללה ב-\(notice.warning.percent)%")
                        .font(.headline)
                    Text(isCritical ? "הטלפון עלול לכבות באמצע השיחה. חברו למטען." : "כדאי לחבר למטען.")
                        .font(.subheadline)
                        .opacity(0.9)
                }
                Spacer()
                Image(systemName: "xmark")
                    .font(.headline)
                    .opacity(0.7)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background((isCritical ? Color.red : Color.orange).opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("הסוללה ב-\(notice.warning.percent) אחוזים")
        .accessibilityHint("הקישו לסגירה")
    }
}
