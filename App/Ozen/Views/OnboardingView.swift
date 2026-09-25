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
    /// The accurate model is right for nearly every phone, so its
    /// alternative stays folded away unless it is already the choice:
    /// "which model?" is not a question for the first minute of setup.
    @State private var showsModelChoice = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    private static let pageCount = 6

    var body: some View {
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
        // Set here, before the safe-area inset composes in the footer:
        // applied after that instead, this same identifier turned up on
        // every descendant it touched (the page indicator, Skip, Next),
        // silently overwriting each one's own -- "onboardingNextButton"
        // was never missing, it just read back as "onboardingScreen".
        .accessibilityIdentifier("onboardingScreen")
        // A plain VStack sibling let the footer's own height compete with
        // the TabView for room at the largest accessibility text sizes:
        // the page dots (drawn inside the TabView's own bounds, not
        // reserved space) ended up overlapping page text, and on some
        // pages the footer was pushed out of the accessible hierarchy
        // entirely. A safe-area inset instead reserves real space for
        // both, unconditionally, and every page's own ScrollView already
        // respects that safe area on its own.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Color.clear.frame(height: 24)
                footer
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
            .background(Color(.systemBackground))
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
        OnboardingPage(symbol: "cpu", title: tr("הכנה חד-פעמית", "One-time setup")) {
            EngineCard(
                title: tr("עברית מדויקת (מומלץ)", "Accurate Hebrew (recommended)"),
                subtitle: tr("מוריד פעם אחת קובץ של כ-\(modelSizeText), ב-Wi-Fi, ומכין אותו לטלפון במשך כמה דקות. אחר כך עובד בלי אינטרנט.", "Downloads a file of about \(modelSizeText) once, over Wi‑Fi, and takes a few minutes to set it up for the phone. After that it works without the internet."),
                symbol: "sparkles",
                selected: viewModel.settings.engine == .whisperKit
            ) {
                Task { await viewModel.setEngine(.whisperKit) }
            }
            if viewModel.settings.engine == .whisperKit {
                DisclosureGroup(isExpanded: $showsModelChoice) {
                    VStack(alignment: .leading, spacing: 8) {
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
                    }
                    .padding(.top, 8)
                } label: {
                    Text(tr("טלפון ישן או איטי?", "An older or slow phone?"))
                        .font(.callout)
                }
                .onAppear {
                    if viewModel.settings.whisperModelVariant != WhisperModelCatalog.recommendedVariant {
                        showsModelChoice = true
                    }
                }
                if let missing = modelStorageShortfall {
                    Label(tr("אין מספיק מקום בטלפון למודל הזה. צריך לפנות עוד \(PhasePresentation.sizeText(megabytes: missing)).", "Not enough room on the phone for this model. \(PhasePresentation.sizeText(megabytes: missing)) more needs to be freed up."), systemImage: "externaldrive.badge.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            EngineCard(
                title: tr("בלי הורדה", "No download"),
                subtitle: tr("הזיהוי של אפל, שמובנה בטלפון. מתחיל מיד, אבל עברית זמינה רק בחלק מגרסאות iOS.", "Apple’s recognition, built into the phone. Starts right away, but Hebrew is only available on some iOS versions."),
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
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
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
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
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
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
                .ozenGlassButton(prominent: true)
                .controlSize(.large)
                .disabled(requesting)
            }
        }
        // Coming back from "Open phone settings" below: re-check rather
        // than leave this page stuck showing "blocked" after she just
        // fixed it. Asking again is safe once denied -- iOS answers with
        // the current status instead of showing the system prompt again.
        .task(id: scenePhase) {
            guard scenePhase == .active, microphone == .denied else { return }
            microphone = await viewModel.requestMicrophonePermission()
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
                // Before the glass button style, not after: applied on
                // the far side of .glassProminent, the identifier stopped
                // reaching XCUITest even though the button rendered and
                // worked fine -- unlike the caption screen's own buttons,
                // which use .buttonStyle(.plain) and never had the issue.
                .accessibilityIdentifier("onboardingNextButton")
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
            return tr("מהיר: מגיב מיד, אבל טועה בהרבה יותר מילים בעברית. רק לטלפון ישן שהמדויק איטי בו.", "Fast: responds instantly, but gets many more Hebrew words wrong. Only for an older phone the accurate one is slow on.")
        default:
            return tr("נבחר מודל אחר בהגדרות.", "A different model is selected in Settings.")
        }
    }
}

private struct OnboardingPage<Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let content: Content

    // A fixed height only ever hid one line of the largest accessibility
    // text sizes; a longer page (namePage, with its extra sentence and
    // NameAlertForm) still had its last line's ascenders poke out above
    // the fade, straight into the dots. Tying both to the same text style
    // as the body content keeps the fade a full line tall at every size.
    @ScaledMetric(relativeTo: .title3) private var bottomFade: CGFloat = 40
    @ScaledMetric(relativeTo: .title3) private var bottomPadding: CGFloat = 48

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                pageContent
            }
            // The page-style TabView draws its dots inside its own
            // bounds, over whatever content is there -- not in reserved
            // space a ScrollView could know to avoid. safeAreaInset
            // couldn't move that (see OnboardingView), so this fades
            // scrolled text to the background colour first instead,
            // the same fix that worked for the caption screen's status
            // bar collision.
            LinearGradient(colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)], startPoint: .top, endPoint: .bottom)
                .frame(height: bottomFade)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var pageContent: some View {
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
        .padding(.bottom, bottomPadding)
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
