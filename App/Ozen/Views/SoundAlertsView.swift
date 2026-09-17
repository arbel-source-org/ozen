import SwiftUI
import OzenKit

/// Which household and safety sounds get a banner. Grouped by importance,
/// each sound individually mutable, and anything this device's classifier
/// doesn't actually know is shown greyed out rather than promised.
struct SoundAlertsView: View {
    @Bindable var viewModel: LiveCaptionViewModel

    private var grouped: [(SoundEvent.Importance, [SoundEvent])] {
        SoundEvent.Importance.allCases.reversed().compactMap { importance in
            let events = SoundEventCatalog.events.filter { $0.importance == importance }
            return events.isEmpty ? nil : (importance, events)
        }
    }

    var body: some View {
        List {
            Section {
                Toggle(tr("התראות על צלילים", "Sound alerts"), isOn: $viewModel.soundAlertPreferences.isEnabled)
                Picker(tr("להתריע על", "Alert for"), selection: $viewModel.soundAlertPreferences.minimumImportance) {
                    ForEach(SoundEvent.Importance.allCases.reversed(), id: \.self) { importance in
                        Text(Self.floorName(importance)).tag(importance)
                    }
                }
                .disabled(!viewModel.soundAlertPreferences.isEnabled)
            } footer: {
                Text(tr("הזיהוי נעשה בטלפון בלבד, על אותו אודיו שמשמש לכתוביות. אותו צליל לא יופיע שוב במשך 20 שניות.", "Detection happens only on the phone, using the same audio as the captions. The same sound won’t appear again for 20 seconds."))
            }

            vibrationSamples

            ForEach(grouped, id: \.0) { importance, events in
                Section {
                    ForEach(events) { event in
                        SoundEventRow(
                            event: event,
                            isSupported: viewModel.isSoundEventSupported(event.identifier),
                            isOn: Binding(
                                get: { !viewModel.soundAlertPreferences.mutedIdentifiers.contains(event.identifier) },
                                set: { viewModel.setSoundEvent(event.identifier, muted: !$0) }
                            ),
                            nearMiss: viewModel.pipeline.soundNearMisses.entry(for: event),
                            isSensitive: Binding(
                                get: { viewModel.soundAlertPreferences.sensitiveIdentifiers.contains(event.identifier) },
                                set: { viewModel.setSoundEvent(event.identifier, sensitive: $0) }
                            )
                        )
                        .disabled(!viewModel.soundAlertPreferences.isEnabled
                                  || importance < viewModel.soundAlertPreferences.minimumImportance)
                    }
                } header: {
                    Label(Self.groupName(importance), systemImage: Self.groupImage(importance))
                }
            }

            if viewModel.knownSoundIdentifiers == nil {
                Section {
                    Text(tr("לא ניתן לבדוק אילו צלילים המכשיר הזה מזהה; כל הצלילים מוצגים.", "Can’t check which sounds this device recognizes; all sounds are shown."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("soundAlertsScreen")
        .navigationTitle(tr("צלילים בבית", "Sounds at home"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Each kind of alert vibrates differently, which only helps once she
    /// knows which is which: these let her, or whoever sets the phone up
    /// with her, feel each one.
    private var vibrationSamples: some View {
        Section {
            sampleButton(tr("חירום: אזעקה, גלאי עשן", "Emergency: alarm, smoke detector"), vibration: .pattern(for: .critical))
            sampleButton(tr("חשוב: פעמון, דפיקה בדלת, בכי של תינוק", "Important: doorbell, knock at the door, baby crying"), vibration: .pattern(for: .high))
            sampleButton(tr("צליל אחר בבית", "Other sound at home"), vibration: .pattern(for: .medium))
            sampleButton(tr("מילה מהרשימה, כמו השם שלך", "A word from the list, like your name"), vibration: .keyword)
            sampleButton(tr("מישהו מתחיל לדבר אחרי שקט", "Someone starts speaking after silence"), vibration: .speechResumed)
        } header: {
            Text(tr("איך כל התראה מרגישה", "How each alert feels"))
        } footer: {
            Text(tr("כשהאפליקציה פתוחה, כל סוג התראה רוטט אחרת, כך שאפשר לדעת מה קרה גם בלי להסתכל. הקישו כדי להרגיש.", "When the app is open, each kind of alert vibrates differently, so you can tell what happened without looking. Tap to feel it."))
        }
    }

    private func sampleButton(_ title: String, vibration: AlertVibration) -> some View {
        Button {
            // Captions may be listening behind this screen.
            viewModel.pipeline.ignoreSounds(whileVibrating: vibration)
            AlertHapticPlayer.shared.play(vibration)
        } label: {
            Label(title, systemImage: "iphone.radiowaves.left.and.right")
        }
    }

    static func floorName(_ importance: SoundEvent.Importance) -> String {
        switch importance {
        case .critical: return tr("רק חירום", "Emergency only")
        case .high: return tr("חשוב ומעלה", "Important and above")
        case .medium: return tr("בית ומעלה", "Home and above")
        case .low: return tr("הכול", "Everything")
        }
    }

    static func groupName(_ importance: SoundEvent.Importance) -> String {
        switch importance {
        case .critical: return tr("חירום", "Emergency")
        case .high: return tr("חשוב", "Important")
        case .medium: return tr("בבית", "At home")
        case .low: return tr("רקע", "Background")
        }
    }

    static func groupImage(_ importance: SoundEvent.Importance) -> String {
        switch importance {
        case .critical: return "exclamationmark.triangle.fill"
        case .high: return "bell.fill"
        case .medium: return "house.fill"
        case .low: return "leaf"
        }
    }

    static func tint(_ importance: SoundEvent.Importance) -> Color {
        switch importance {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .blue
        case .low: return .secondary
        }
    }
}

private struct SoundEventRow: View {
    let event: SoundEvent
    let isSupported: Bool
    @Binding var isOn: Bool
    let nearMiss: SoundNearMisses.Entry?
    @Binding var isSensitive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isOn) {
                HStack(spacing: 12) {
                    Image(systemName: event.systemImage)
                        .foregroundStyle(SoundAlertsView.tint(event.importance))
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.name)
                        if !isSupported {
                            Text(tr("לא נתמך במכשיר הזה", "Not supported on this device"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .disabled(!isSupported)
            .foregroundStyle(isSupported ? .primary : .secondary)

            // Only while it's genuinely actionable: once marked sensitive,
            // the sound alerts at its new, lower floor and stops being a
            // near miss, so this naturally disappears on its own next time
            // it's heard -- no separate "already sensitive" state to show.
            if isSupported, isOn, let nearMiss {
                sensitivityNudge(nearMiss)
            }
        }
    }

    @ViewBuilder
    private func sensitivityNudge(_ nearMiss: SoundNearMisses.Entry) -> some View {
        HStack {
            Text(tr(
                "נשמע ב-\(Int((nearMiss.bestConfidence * 100).rounded()))%, קצת חלש מדי",
                "Heard at \(Int((nearMiss.bestConfidence * 100).rounded()))%, a bit too faint"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Toggle(isOn: $isSensitive) {
                Text(tr("להתריע גם על צליל חלש יותר", "Alert on a fainter sound too"))
                    .font(.caption.weight(.semibold))
            }
            .toggleStyle(.button)
            .controlSize(.small)
        }
        .accessibilityIdentifier("soundSensitivityToggle-\(event.identifier)")
    }
}
