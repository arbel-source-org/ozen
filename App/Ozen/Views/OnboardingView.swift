import SwiftUI
import UIKit
import OzenKit

/// First launch. Five short pages in large type: what the app is, how it
/// works, which engine (with the model download explained before it
/// happens), the microphone permission asked with a reason, and go.
struct OnboardingView: View {
    @Bindable var viewModel: LiveCaptionViewModel
    @State private var page = 0
    @State private var microphone: AudioPermission?
    @State private var notificationsAllowed: Bool?
    @State private var requesting = false
    @Environment(\.openURL) private var openURL

    private static let pageCount = 5

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcomePage.tag(0)
                howItWorksPage.tag(1)
                enginePage.tag(2)
                microphonePage.tag(3)
                readyPage.tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            footer
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    // MARK: - Pages

    private var welcomePage: some View {
        OnboardingPage(symbol: "ear", title: "אוזן") {
            Text("כתוביות חיות לשיחה.")
            Text("מה שאומרים לידך מופיע על המסך, באותיות גדולות, תוך כדי הדיבור.")
            Text("הכל קורה בתוך הטלפון. שום דבר לא נשלח לאינטרנט.")
        }
    }

    private var howItWorksPage: some View {
        OnboardingPage(symbol: "text.bubble", title: "איך זה עובד") {
            OnboardingRow(symbol: "mic.fill", text: "מניחים את הטלפון על השולחן, והכתוביות רצות לבד.")
            OnboardingRow(symbol: "person.2.fill", text: "האפליקציה מבדילה בין דוברים ויכולה ללמוד את השמות שלהם.")
            OnboardingRow(symbol: "bell.badge.fill", text: "היא מתריעה על שמות שחשובים לך, ועל צלצול בדלת או אזעקה.")
            OnboardingRow(symbol: "keyboard", text: "ואפשר להקליד תשובה, והטלפון יגיד אותה בקול.")
        }
    }

    private var enginePage: some View {
        OnboardingPage(symbol: "cpu", title: "איזה מנוע?") {
            EngineCard(
                title: "Whisper (מומלץ)",
                subtitle: "מדויק יותר בעברית. מוריד פעם אחת קובץ של כ-\(modelSizeText), ב-Wi-Fi, ואז עובד בלי אינטרנט.",
                symbol: "sparkles",
                selected: viewModel.settings.engine == .whisperKit
            ) {
                Task { await viewModel.setEngine(.whisperKit) }
            }
            if viewModel.settings.engine == .whisperKit {
                Picker("מודל", selection: Binding(
                    get: { viewModel.settings.whisperModelVariant },
                    set: { variant in Task { await viewModel.setWhisperModel(variant) } }
                )) {
                    Text("מדויק").tag(WhisperModelCatalog.recommendedVariant)
                    Text("מהיר").tag("small")
                }
                .pickerStyle(.segmented)
                Text(modelChoiceNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            EngineCard(
                title: "Apple",
                subtitle: "מובנה בטלפון, מתחיל מיד. עברית זמינה רק בחלק מגרסאות iOS.",
                symbol: "apple.logo",
                selected: viewModel.settings.engine == .appleSpeech
            ) {
                Task { await viewModel.setEngine(.appleSpeech) }
            }
            Text("אפשר להחליף בכל רגע בהגדרות.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var microphonePage: some View {
        OnboardingPage(symbol: "mic.circle", title: "המיקרופון") {
            Text("כדי לכתב את השיחה, אוזן צריכה להאזין דרך המיקרופון.")
            Text("ההקלטה לא נשמרת ולא יוצאת מהטלפון.")
            switch microphone {
            case .granted:
                Label("המיקרופון מאושר", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3.weight(.semibold))
                Text("ועוד דבר אחד: כשהטלפון בכיס או נעול, אוזן יכולה להודיע על צלצול בדלת, אזעקה או השם שלך.")
                if let notificationsAllowed {
                    Label(notificationsAllowed ? "ההתראות מאושרות" : "בלי התראות. אפשר לשנות בהגדרות.", systemImage: notificationsAllowed ? "checkmark.circle.fill" : "bell.slash")
                        .foregroundStyle(notificationsAllowed ? Color.green : Color.secondary)
                } else {
                    Button {
                        Task { notificationsAllowed = await AlertNotifier.shared.requestAuthorization() }
                    } label: {
                        Label("לאשר התראות", systemImage: "bell.badge")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            case .denied:
                VStack(alignment: .leading, spacing: 12) {
                    Label("המיקרופון חסום", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.title3.weight(.semibold))
                    Text("בלי מיקרופון אין כתוביות. אפשר לאשר בהגדרות הטלפון.")
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Label("פתיחת הגדרות הטלפון", systemImage: "gear")
                    }
                    .buttonStyle(.bordered)
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
                    Label("לאשר את המיקרופון", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(requesting)
            }
        }
    }

    private var readyPage: some View {
        OnboardingPage(symbol: "checkmark.seal", title: "מוכן") {
            if viewModel.settings.engine == .whisperKit {
                Text("בהפעלה הראשונה אוזן תוריד את מודל השפה. זה לוקח כמה דקות ומוצג על המסך. אחר כך — מיד.")
            } else {
                Text("בהפעלה הראשונה iOS עשוי לבקש אישור לזיהוי דיבור.")
            }
            Text("הכפתור למטה מתחיל את הכתוביות. בהצלחה, סבתא.")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if page < Self.pageCount - 1 {
                Button("דילוג") {
                    finish()
                }
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation { page += 1 }
                } label: {
                    Text("הבא")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    finish()
                } label: {
                    Label("להתחיל", systemImage: "captions.bubble.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
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

    private var modelChoiceNote: String {
        switch viewModel.settings.whisperModelVariant {
        case WhisperModelCatalog.recommendedVariant:
            return "מדויק: עברית טובה בהרבה, מתעדכן קצת יותר לאט. מתאים לאייפון חדש."
        case "small":
            return "מהיר: מגיב מיד, עם יותר טעויות בעברית. מתאים לטלפון ישן."
        default:
            return "נבחר מודל אחר בהגדרות."
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
                Text(title)
                    .font(.system(size: 36, weight: .bold))
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
