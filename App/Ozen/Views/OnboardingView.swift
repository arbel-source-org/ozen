import SwiftUI
import UIKit
import OzenKit
import OzenPlatform

/// First launch. Six short pages in large type: what the app is, how it
/// works, which engine (with the model download explained before it
/// happens), the microphone permission asked with a reason, the words
/// that should buzz the phone (her name), and go.
struct OnboardingView: View {
    @Bindable var viewModel: LiveCaptionViewModel
    @State private var page = 0
    @State private var microphone: AudioPermission?
    @State private var notificationsAllowed: Bool?
    @State private var requesting = false
    @Environment(\.openURL) private var openURL

    private static let pageCount = 6

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcomePage.tag(0)
                howItWorksPage.tag(1)
                enginePage.tag(2)
                microphonePage.tag(3)
                namePage.tag(4)
                readyPage.tag(5)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            footer
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Pages

    private var welcomePage: some View {
        OnboardingPage(symbol: "ear", title: tr("אוזן", "Ozen")) {
            Text(tr("כתוביות חיות לשיחה.", "Live captions for conversation."))
            Text(tr("מה שאומרים לידך מופיע על המסך, באותיות גדולות, תוך כדי הדיבור.", "What’s said near you appears on the screen, in large letters, as it’s spoken."))
            Text(tr("הכל קורה בתוך הטלפון. שום דבר לא נשלח לאינטרנט.", "It all happens on the phone. Nothing is sent to the internet."))
        }
    }

    private var howItWorksPage: some View {
        OnboardingPage(symbol: "text.bubble", title: tr("איך זה עובד", "How it works")) {
            OnboardingRow(symbol: "mic.fill", text: tr("מניחים את הטלפון על השולחן, והכתוביות רצות לבד.", "Set the phone on the table, and the captions run on their own."))
            OnboardingRow(symbol: "person.2.fill", text: tr("האפליקציה מבדילה בין דוברים ויכולה ללמוד את השמות שלהם.", "The app tells speakers apart and can learn their names."))
            OnboardingRow(symbol: "bell.badge.fill", text: tr("היא מתריעה על שמות שחשובים לך, ועל צלצול בדלת או אזעקה, ברטט שונה לכל אחד.", "It alerts you to names that matter to you, and to a doorbell or alarm, with a different vibration for each."))
            OnboardingRow(symbol: "keyboard", text: tr("ואפשר להקליד תשובה, והטלפון יגיד אותה בקול.", "And you can type a reply, and the phone will speak it aloud."))
        }
    }

    private var enginePage: some View {
        OnboardingPage(symbol: "cpu", title: tr("איזה מנוע?", "Which engine?")) {
            EngineCard(
                title: tr("Whisper (מומלץ)", "Whisper (recommended)"),
                subtitle: tr("מדויק יותר בעברית. מוריד פעם אחת קובץ של כ-\(modelSizeText), ב-Wi-Fi, ואז עובד בלי אינטרנט.", "More accurate in Hebrew. Downloads a file of about \(modelSizeText) once, over Wi‑Fi, then works without the internet."),
                symbol: "sparkles",
                selected: viewModel.settings.engine == .whisperKit
            ) {
                Task { await viewModel.setEngine(.whisperKit) }
            }
            if viewModel.settings.engine == .whisperKit {
                Picker(tr("מודל", "Model"), selection: Binding(
                    get: { viewModel.settings.whisperModelVariant },
                    set: { variant in Task { await viewModel.setWhisperModel(variant) } }
                )) {
                    Text(tr("מדויק", "Accurate")).tag(WhisperModelCatalog.recommendedVariant)
                    Text(tr("מהיר", "Fast")).tag("small")
                }
                .pickerStyle(.segmented)
                Text(modelChoiceNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let missing = modelStorageShortfall {
                    Label(tr("אין מספיק מקום בטלפון למודל הזה. צריך לפנות עוד \(PhasePresentation.sizeText(megabytes: missing)).", "Not enough room on the phone for this model. \(PhasePresentation.sizeText(megabytes: missing)) more needs to be freed up."), systemImage: "externaldrive.badge.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            EngineCard(
                title: tr("Apple", "Apple"),
                subtitle: tr("מובנה בטלפון, מתחיל מיד. עברית זמינה רק בחלק מגרסאות iOS.", "Built into the phone, starts right away. Hebrew is only available on some iOS versions."),
                symbol: "apple.logo",
                selected: viewModel.settings.engine == .appleSpeech
            ) {
                Task { await viewModel.setEngine(.appleSpeech) }
            }
            Text(tr("אפשר להחליף בכל רגע בהגדרות.", "You can switch anytime in Settings."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var microphonePage: some View {
        OnboardingPage(symbol: "mic.circle", title: tr("המיקרופון", "The microphone")) {
            Text(tr("כדי לכתב את השיחה, אוזן צריכה להאזין דרך המיקרופון.", "To caption the conversation, Ozen needs to listen through the microphone."))
            Text(tr("ההקלטה לא נשמרת ולא יוצאת מהטלפון.", "Nothing recorded is saved or leaves the phone."))
            switch microphone {
            case .granted:
                Label(tr("המיקרופון מאושר", "Microphone approved"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3.weight(.semibold))
                Text(tr("ועוד דבר אחד: כשהטלפון בכיס או נעול, אוזן יכולה להודיע על צלצול בדלת, אזעקה או השם שלך.", "One more thing: when the phone is in a pocket or locked, Ozen can notify you about a doorbell, an alarm, or your name."))
                if let notificationsAllowed {
                    Label(notificationsAllowed ? tr("ההתראות מאושרות", "Notifications approved") : tr("בלי התראות. אפשר לשנות בהגדרות.", "No notifications. This can be changed in Settings."), systemImage: notificationsAllowed ? "checkmark.circle.fill" : "bell.slash")
                        .foregroundStyle(notificationsAllowed ? Color.green : Color.secondary)
                } else {
                    Button {
                        Task { notificationsAllowed = await AlertNotifier.shared.requestAuthorization() }
                    } label: {
                        Label(tr("לאשר התראות", "Approve notifications"), systemImage: "bell.badge")
                            .frame(maxWidth: .infinity)
                    }
                    .ozenGlassButton()
                    .controlSize(.large)
                }
            case .denied:
                VStack(alignment: .leading, spacing: 12) {
                    Label(tr("המיקרופון חסום", "Microphone blocked"), systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.title3.weight(.semibold))
                    Text(tr("בלי מיקרופון אין כתוביות. אפשר לאשר בהגדרות הטלפון.", "Without a microphone there are no captions. It can be approved in the phone’s Settings."))
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Label(tr("פתיחת הגדרות הטלפון", "Open phone settings"), systemImage: "gear")
                    }
                    .ozenGlassButton()
                    .controlSize(.large)
                }
            case nil:
                Button {
                    requesting = true
                    Task {
                        microphone = await viewModel.requestMicrophonePermission()
                        requesting = false
                    }
                } label: {
                    Label(tr("לאשר את המיקרופון", "Approve the microphone"), systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .ozenGlassButton(prominent: true)
                .controlSize(.large)
                .disabled(requesting)
            }
        }
    }

    /// The alert for her name only works once someone has typed the name
    /// in, and the screen for that is three levels deep in Settings; here
    /// it's asked for while the family member setting the phone up is
    /// still holding it.
    private var namePage: some View {
        OnboardingPage(symbol: "bell.and.waves.left.and.right", title: tr("כשקוראים לך", "When you’re called")) {
            Text(tr("כשמישהו אומר את השם שלך, הטלפון רוטט והשורה מסומנת, גם כשלא מסתכלים על המסך.", "When someone says your name, the phone vibrates and the line is highlighted, even when no one is looking at the screen."))
            NameAlertForm(viewModel: viewModel)
            Text(tr("אפשר להוסיף עוד מילים, או למחוק, בהגדרות ← התראות ← מילים חשובות.", "More words can be added or removed in Settings ← Notifications ← Important words."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var readyPage: some View {
        OnboardingPage(symbol: "checkmark.seal", title: tr("מוכן", "Ready")) {
            if viewModel.settings.engine == .whisperKit {
                Text(tr("בהפעלה הראשונה אוזן תוריד את מודל השפה. זה לוקח כמה דקות ומוצג על המסך. אחר כך — מיד.", "The first time it runs, Ozen will download the language model. This takes a few minutes and shows on the screen. After that — instantly."))
            } else {
                Text(tr("בהפעלה הראשונה iOS עשוי לבקש אישור לזיהוי דיבור.", "The first time it runs, iOS may ask for permission to recognize speech."))
            }
            Text(tr("הכפתור למטה מתחיל את הכתוביות. בהצלחה, סבתא.", "The button below starts the captions. Good luck, Grandma."))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if page < Self.pageCount - 1 {
                Button(tr("דילוג", "Skip")) {
                    finish()
                }
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation { page += 1 }
                } label: {
                    Text(tr("הבא", "Next"))
                        .frame(minWidth: 120)
                }
                .ozenGlassButton(prominent: true)
                .controlSize(.large)
            } else {
                Button {
                    finish()
                } label: {
                    Label(tr("להתחיל", "Start"), systemImage: "captions.bubble.fill")
                        .frame(maxWidth: .infinity)
                }
                .ozenGlassButton(prominent: true)
                .controlSize(.large)
            }
        }
        .font(.title3.weight(.semibold))
    }

    private func finish() {
        withAnimation { viewModel.completeOnboarding() }
    }

    private var modelSizeText: String {
        WhisperModelCatalog.option(for: viewModel.settings.whisperModelVariant)?.sizeLabel ?? "500 MB"
    }

    /// How much room to free before the chosen model fits, said up front
    /// rather than after the download has been started.
    private var modelStorageShortfall: Int? {
        guard let size = WhisperModelCatalog.option(for: viewModel.settings.whisperModelVariant)?.installMegabytes,
              !WhisperModelStore().isInstalled(viewModel.settings.whisperModelVariant)
        else { return nil }
        return StorageSpaceGate.shortfallMegabytes(downloadMegabytes: size, availableBytes: DeviceStorage.availableBytes())
    }

    private var modelChoiceNote: String {
        switch viewModel.settings.whisperModelVariant {
        case WhisperModelCatalog.recommendedVariant:
            return tr("מדויק: עברית טובה בהרבה, מתעדכן קצת יותר לאט. מתאים לאייפון חדש.", "Accurate: much better Hebrew, updates a bit slower. Good for a newer iPhone.")
        case "small":
            return tr("מהיר: מגיב מיד, עם יותר טעויות בעברית. מתאים לטלפון ישן.", "Fast: responds instantly, with more Hebrew mistakes. Good for an older phone.")
        default:
            return tr("נבחר מודל אחר בהגדרות.", "A different model is selected in Settings.")
        }
    }
}

private struct OnboardingPage<Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: symbol)
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
                    .accessibilityHidden(true)
                Text(title)
                    // Scales with the phone's text size, like everything
                    // else here: the largest sizes are the ones she may use.
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 8)
                content
                    .font(.title3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 48)
        }
    }
}

private struct OnboardingRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct EngineCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: selected ? "checkmark.circle.fill" : symbol)
                    .font(.title)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
