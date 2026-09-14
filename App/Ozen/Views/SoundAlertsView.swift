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
                Toggle("התראות על צלילים", isOn: $viewModel.soundAlertPreferences.isEnabled)
                Picker("להתריע על", selection: $viewModel.soundAlertPreferences.minimumImportance) {
                    ForEach(SoundEvent.Importance.allCases.reversed(), id: \.self) { importance in
                        Text(Self.floorName(importance)).tag(importance)
                    }
                }
                .disabled(!viewModel.soundAlertPreferences.isEnabled)
            } footer: {
                Text("הזיהוי נעשה בטלפון בלבד, על אותו אודיו שמשמש לכתוביות. אותו צליל לא יופיע שוב במשך 20 שניות.")
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
                    Text("לא ניתן לבדוק אילו צלילים המכשיר הזה מזהה; כל הצלילים מוצגים.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("צלילים בבית")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Each kind of alert vibrates differently, which only helps once she
    /// knows which is which: these let her, or whoever sets the phone up
    /// with her, feel each one.
    private var vibrationSamples: some View {
        Section {
            sampleButton("חירום: אזעקה, גלאי עשן", vibration: .pattern(for: .critical))
            sampleButton("חשוב: פעמון, דפיקה בדלת, בכי של תינוק", vibration: .pattern(for: .high))
            sampleButton("צליל אחר בבית", vibration: .pattern(for: .medium))
            sampleButton("מילה מהרשימה, כמו השם שלך", vibration: .keyword)
        } header: {
            Text("איך כל התראה מרגישה")
        } footer: {
            Text("כשהאפליקציה פתוחה, כל סוג התראה רוטט אחרת, כך שאפשר לדעת מה קרה גם בלי להסתכל. הקישו כדי להרגיש.")
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
        case .critical: return "רק חירום"
        case .high: return "חשוב ומעלה"
        case .medium: return "בית ומעלה"
        case .low: return "הכול"
        }
    }

    static func groupName(_ importance: SoundEvent.Importance) -> String {
        switch importance {
        case .critical: return "חירום"
        case .high: return "חשוב"
        case .medium: return "בבית"
        case .low: return "רקע"
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

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                Image(systemName: event.systemImage)
                    .foregroundStyle(SoundAlertsView.tint(event.importance))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.name)
                    if !isSupported {
                        Text("לא נתמך במכשיר הזה")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(!isSupported)
        .foregroundStyle(isSupported ? .primary : .secondary)
    }
}
