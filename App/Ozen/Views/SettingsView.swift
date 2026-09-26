import SwiftUI
import UIKit
import AppIntents
import OzenKit
import OzenPlatform

struct SettingsView: View {
    @Bindable var viewModel: LiveCaptionViewModel
    @State private var showingEnrollment = false
    @State private var confirmingClear = false
    @State private var renamingProfile: SpeakerProfile?
    @State private var renameText = ""
    /// A saved speaker swiped away, waiting for a yes: getting them back
    /// means recording their voice again.
    @State private var pendingSpeakerRemoval: String?
    /// iOS has notifications for Ozen switched off, so the "notify when the
    /// screen is off" switch can't do anything until they're allowed.
    @State private var notificationsBlocked = false
    @State private var testNotificationSent = false
    /// iOS has Live Activities for Ozen switched off, so the lock screen
    /// captions switch can't show anything until they're allowed.
    @State private var lockScreenBlocked = false
    /// What's typed in the OpenRouter key field. The saved key itself is
    /// never read back onto the screen, only whether there is one.
    @State private var cloudKeyDraft = ""
    @State private var hasCloudKey = CloudKeyStore.hasKey
    @State private var cloudKeySaveFailed = false
    @State private var homeServerAddressDraft = ""
    @State private var homeServerCodeDraft = ""
    @State private var hasHomeServerCode = HomeServerCodeStore.hasKey
    @State private var homeServerCheck: HomeServerCheck?
    @State private var isCheckingHomeServer = false
    @State private var confirmingHomeServerCodeDelete = false
    @State private var confirmingCloudKeyDelete = false
    @State private var confirmingWalkthrough = false
    @State private var homeServerCodeSaveFailed = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // A slider's own label ("רגישות הפרדת דוברים" — "Speaker separation
    // sensitivity" is three words) can wrap at the largest accessibility
    // text size; a plain HStack then let its trailing value or extreme
    // label interleave with the wrapped line instead of sitting below it.
    private var sliderLabelLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout())
    }
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            // Hers first: how captions look, what alerts her, the voice,
            // the language and her saved conversations. The engine, models
            // and keys, which the gear used to open onto, come after a
            // line saying they are for whoever set up the phone.
            Form {
                displaySection
                alertsSection
                speechSection
                languageSection
                historySection
                helperSettingsNote
                engineSection
                switch viewModel.settings.engine {
                case .whisperKit: whisperModelSection
                case .appleSpeech: appleSpeechSection
                case .cloud: cloudSection
                case .homeServer: homeServerSection
                }
                vocabularySection
                speakersSection
                behaviourSection
                siriSection
                maintenanceSection
                aboutSection
            }
            .accessibilityIdentifier("settingsScreen")
            .navigationTitle(tr("הגדרות", "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("סגור", "Close")) { dismiss() }
                }
            }
            .sheet(isPresented: $showingEnrollment) {
                SpeakerEnrollmentView(viewModel: viewModel)
            }
            .alert(
                tr("שינוי שם", "Rename"),
                isPresented: Binding(get: { renamingProfile != nil }, set: { if !$0 { renamingProfile = nil } })
            ) {
                TextField(tr("שם", "Name"), text: $renameText)
                Button(tr("שמירה", "Save")) {
                    if let profile = renamingProfile {
                        viewModel.renameProfile(id: profile.id, to: renameText)
                    }
                    renamingProfile = nil
                }
                Button(tr("ביטול", "Cancel"), role: .cancel) { renamingProfile = nil }
            } message: {
                Text(tr("השם החדש יופיע גם על השורות שכבר בכתוביות.", "The new name will also appear on lines already in the captions."))
            }
            .confirmationDialog(
                tr("למחוק את \(pendingSpeakerRemoval ?? "") מהדוברים השמורים?", "Delete \(pendingSpeakerRemoval ?? "") from saved speakers?"),
                isPresented: Binding(get: { pendingSpeakerRemoval != nil }, set: { if !$0 { pendingSpeakerRemoval = nil } }),
                titleVisibility: .visible,
                presenting: pendingSpeakerRemoval
            ) { name in
                Button(tr("מחיקה", "Delete"), role: .destructive) { viewModel.removeSpeaker(named: name) }
                Button(tr("ביטול", "Cancel"), role: .cancel) {}
            } message: { _ in
                Text(tr("כדי שיזוהו שוב בשמם צריך להקליט את הקול מחדש.", "To be recognized by name again, their voice needs to be recorded again."))
            }
            .confirmationDialog(tr("למחוק את כל הכתוביות מהמסך?", "Delete all captions from the screen?"), isPresented: $confirmingClear, titleVisibility: .visible) {
                Button(tr("מחיקה", "Delete"), role: .destructive) { viewModel.clearTranscript() }
                Button(tr("ביטול", "Cancel"), role: .cancel) {}
            }
        }
    }

    /// A menu shows the chosen theme's name beside the label, and at the
    /// largest text sizes there is room for two letters of it. There,
    /// the three themes are rows of their own with a checkmark.
    @ViewBuilder
    private var themePicker: some View {
        let picker = Picker(tr("צבעים", "Colors"), selection: $viewModel.display.theme) {
            ForEach(DisplayPreferences.Theme.allCases, id: \.self) { theme in
                Text(CaptionTheme.name(for: theme)).tag(theme)
            }
        }
        if dynamicTypeSize.isAccessibilitySize {
            picker.pickerStyle(.inline)
        } else {
            picker
        }
    }

    private var helperSettingsNote: some View {
        Section {
            Label(tr("ההגדרות מכאן והלאה הן בשביל מי שהתקין את הטלפון", "The settings from here on are for whoever set up the phone"), systemImage: "wrench.and.screwdriver")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Engine

    private var engineBinding: Binding<TranscriptionEngineKind> {
        Binding(
            get: { viewModel.settings.engine },
            set: { kind in Task { await viewModel.setEngine(kind) } }
        )
    }

    private var engineSection: some View {
        Section {
            Picker(tr("מנוע תמלול", "Transcription engine"), selection: engineBinding) {
                ForEach(TranscriptionEngineKind.allCases, id: \.self) { kind in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(engineName(kind))
                        Text(engineSummary(kind))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(kind)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text(tr("מנוע תמלול", "Transcription engine"))
        } footer: {
            Text(tr("שינוי המנוע מפעיל מחדש את ההאזנה. הכתוביות שכבר על המסך נשארות.", "Changing the engine restarts listening. Captions already on screen stay."))
        }
    }

    private func engineName(_ kind: TranscriptionEngineKind) -> String {
        switch kind {
        case .whisperKit: return tr("Whisper (במכשיר)", "Whisper (on device)")
        case .appleSpeech: return tr("זיהוי הדיבור של אפל", "Apple's speech recognition")
        case .cloud: return tr("תמלול בענן \u{2066}(OpenRouter)\u{2069}", "Cloud transcription (OpenRouter)")
        case .homeServer: return tr("המחשב בבית", "Home computer")
        }
    }

    private func engineSummary(_ kind: TranscriptionEngineKind) -> String {
        switch kind {
        case .whisperKit: return tr("מודל קוד פתוח שרץ על הטלפון. עברית טובה, אפשר לבחור גודל מודל.", "An open-source model that runs on the phone. Good Hebrew, and you can choose the model size.")
        case .appleSpeech: return tr("מובנה ב‑iOS. מהיר מאוד, אבל עברית במכשיר לא זמינה בכל גרסה.", "Built into iOS. Very fast, but on-device Hebrew isn’t available in every version.")
        case .cloud: return tr("מודל באינטרנט, לטלפון שאיטי מדי למודל שבתוכו. בעברית הוא טועה יותר מהמודל שבטלפון. צריך אינטרנט ומפתח \u{2066}OpenRouter.\u{2069}", "A model online, for a phone too slow for the one inside it. It gets more Hebrew wrong than the phone’s own model. Needs internet and an OpenRouter key.")
        case .homeServer: return tr("מחשב של המשפחה עם כרטיס מסך כותב את הכתוביות: אותו מודל עברית, מהר בהרבה, והטלפון לא מתחמם. כשאין אליו חיבור, הטלפון ממשיך לבד.", "A family computer with a graphics card writes the captions: the same Hebrew model, much faster, and the phone stays cool. When it can’t be reached, the phone carries on by itself.")
        }
    }

    // MARK: - Whisper model

    private var whisperModelSection: some View {
        Section {
            NavigationLink {
                ModelManagerView(viewModel: viewModel)
            } label: {
                LabeledContent(tr("מודל", "Model")) {
                    Text(currentModelLabel)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("modelManagerRow")
            if viewModel.settings.runsWeakerModel, let recommended = WhisperModelCatalog.option(for: WhisperModelCatalog.recommendedVariant) {
                Button {
                    Task { await viewModel.acceptBetterModelOffer() }
                } label: {
                    Label(tr("המודל הזה טועה בהרבה מילים בעברית. הקישו כדי לעבור ל-\(recommended.displayName), \(recommended.sizeLabel)", "This model gets many Hebrew words wrong. Tap to switch to \(recommended.displayName), \(recommended.sizeLabel)"), systemImage: "sparkles")
                }
                .accessibilityIdentifier("switchToRecommendedModel")
            }
            Toggle(tr("להוריד מודלים גם בחבילת הגלישה", "Download models on cellular data too"), isOn: $viewModel.allowCellularModelDownload)
        } header: {
            Text("Whisper")
        } footer: {
            Text(tr("מודל גדול יותר מבין עברית טוב יותר אבל מגיב לאט יותר. \u{2066}\"\(recommendedModelName)\"\u{2069} הוא הבחירה המומלצת לאייפון הזה. מודלים שוקלים מאות MB, ולכן כברירת מחדל הם יורדים רק ב-Wi-Fi.", "A bigger model understands Hebrew better but responds more slowly. “\(recommendedModelName)” is the recommended choice for this iPhone. Models weigh hundreds of MB, so by default they only download over Wi‑Fi."))
        }
    }

    private var recommendedModelName: String {
        WhisperModelCatalog.option(for: WhisperModelCatalog.recommendedVariant)?.displayName ?? WhisperModelCatalog.recommendedVariant
    }

    private var currentModelLabel: String {
        let variant = viewModel.settings.whisperModelVariant
        guard let option = WhisperModelCatalog.option(for: variant) else { return variant }
        return "\(option.displayName) · \(option.sizeLabel)"
    }

    // MARK: - Apple speech

    private var serverFallbackBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.allowServerFallbackForAppleSpeech },
            set: { allowed in Task { await viewModel.setAllowServerFallback(allowed) } }
        )
    }

    private var appleSpeechSection: some View {
        Section {
            Toggle(tr("לאפשר עיבוד בשרתי אפל", "Allow processing on Apple’s servers"), isOn: serverFallbackBinding)
        } header: {
            Text(tr("זיהוי הדיבור של אפל", "Apple’s speech recognition"))
        } footer: {
            Text(tr("כבוי: הכול נשאר בטלפון. אם עברית במכשיר לא זמינה, המנוע פשוט לא יעבוד ותוצע חלופה. דולק: כשאין מודל עברית במכשיר, האודיו נשלח לשרתי אפל לזיהוי. זו החלטת פרטיות שלכם — האפליקציה אף פעם לא עושה את זה לבד.", "Off: everything stays on the phone. If on-device Hebrew isn’t available, the engine simply won’t work and an alternative will be suggested. On: when there’s no on-device Hebrew model, the audio is sent to Apple’s servers for recognition. This is your privacy choice — the app never does this on its own."))
        }
    }

    // MARK: - Cloud

    private var cloudModelBinding: Binding<String> {
        Binding(
            get: { viewModel.settings.cloudModel },
            set: { model in Task { await viewModel.setCloudModel(model) } }
        )
    }

    private var cloudSection: some View {
        Section {
            if hasCloudKey {
                Label(tr("מפתח שמור בטלפון", "Key saved on the phone"), systemImage: "key.fill")
                    .foregroundStyle(.green)
            }
            SecureField(hasCloudKey ? tr("מפתח חדש במקום השמור", "New key instead of the saved one") : tr("הדביקו כאן מפתח OpenRouter", "Paste your OpenRouter key here"), text: $cloudKeyDraft)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(saveCloudKey)
            if !cloudKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(tr("שמירת המפתח", "Save key"), action: saveCloudKey)
            }
            if cloudKeySaveFailed {
                Label(tr("המפתח לא נשמר. נסו שוב.", "The key wasn’t saved. Try again."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if hasCloudKey {
                Button(tr("מחיקת המפתח", "Delete key"), role: .destructive) {
                    confirmingCloudKeyDelete = true
                }
                .confirmationDialog(tr("למחוק את מפתח הענן?", "Delete the cloud key?"), isPresented: $confirmingCloudKeyDelete, titleVisibility: .visible) {
                    Button(tr("למחוק", "Delete"), role: .destructive) {
                        CloudKeyStore.remove()
                        hasCloudKey = false
                        Task { await viewModel.cloudKeyChanged() }
                    }
                } message: {
                    Text(tr("בלי המפתח הכתוביות לא יגיעו מהענן, עד שיכניסו אותו שוב.", "Without the key, captions can’t come from the cloud until it’s entered again."))
                }
            }
            Picker(tr("מודל", "Model"), selection: cloudModelBinding) {
                Text(tr("מהיר (Gemini Flash Lite)", "Fast (Gemini Flash Lite)")).tag(CloudSpeech.fastModel)
                Text(tr("מדויק יותר, קצת איטי (Gemini Flash)", "More accurate, a bit slower (Gemini Flash)")).tag(CloudSpeech.accurateModel)
            }
        } header: {
            Text(tr("תמלול בענן", "Cloud transcription"))
        } footer: {
            Text(tr("הקול נשלח דרך האינטרנט ל‑OpenRouter, ומשם לדגם של Google שכותב את הכתוביות. רק כשמישהו מדבר, משפט אחרי משפט. שעת דיבור רצוף עולה בערך 15 סנט מהקרדיט של המפתח (המדויק יותר: כ‑30 סנט). המפתח נשמר רק בטלפון. בלי אינטרנט, מודל ה‑Whisper שכבר בטלפון ממשיך לבד.", "The audio is sent over the internet to OpenRouter, and from there to a Google model that writes the captions. Only while someone is speaking, sentence by sentence. An hour of continuous speech costs about 15 cents from the key’s credit (the more accurate one: about 30 cents). The key is saved only on the phone. Without internet, a Whisper model already on the phone carries on by itself."))
        }
    }

    private var homeServerSection: some View {
        Section {
            TextField(tr("כתובת המחשב", "Computer address"), text: $homeServerAddressDraft)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(saveHomeServerAddress)
                .onAppear {
                    homeServerAddressDraft = viewModel.settings.homeServerAddress
                    hasHomeServerCode = HomeServerCodeStore.hasKey
                }
            if homeServerAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines) != viewModel.settings.homeServerAddress {
                Button(tr("שמירת הכתובת", "Save address"), action: saveHomeServerAddress)
            }
            if !homeServerAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, HomeServer.url(from: homeServerAddressDraft) == nil {
                Label(tr("הכתובת לא נראית תקינה", "That address doesn’t look right"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if hasHomeServerCode {
                Label(tr("קוד צימוד שמור בטלפון", "Pairing code saved on the phone"), systemImage: "key.fill")
                    .foregroundStyle(.green)
            }
            SecureField(hasHomeServerCode ? tr("קוד חדש במקום השמור", "New code instead of the saved one") : tr("קוד הצימוד מהמחשב", "The pairing code from the computer"), text: $homeServerCodeDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(saveHomeServerCode)
            if !homeServerCodeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(tr("שמירת הקוד", "Save code"), action: saveHomeServerCode)
            }
            if homeServerCodeSaveFailed {
                Label(tr("הקוד לא נשמר. נסו שוב.", "The code wasn’t saved. Try again."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if hasHomeServerCode, HomeServer.url(from: viewModel.settings.homeServerAddress) != nil {
                Button {
                    isCheckingHomeServer = true
                    homeServerCheck = nil
                    Task {
                        let check = await viewModel.checkHomeServer()
                        homeServerCheck = check
                        isCheckingHomeServer = false
                        UIAccessibility.post(notification: .announcement, argument: Self.homeServerCheckText(check))
                    }
                } label: {
                    HStack {
                        Text(tr("בדיקת חיבור", "Test connection"))
                        if isCheckingHomeServer {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isCheckingHomeServer)
                .accessibilityValue(isCheckingHomeServer ? tr("בודק…", "Checking…") : "")
                if let homeServerCheck {
                    homeServerCheckLabel(homeServerCheck)
                }
            }
            if hasHomeServerCode {
                Button(tr("מחיקת הקוד", "Delete code"), role: .destructive) {
                    confirmingHomeServerCodeDelete = true
                }
                .confirmationDialog(tr("למחוק את קוד המחשב?", "Delete the computer’s code?"), isPresented: $confirmingHomeServerCodeDelete, titleVisibility: .visible) {
                    Button(tr("למחוק", "Delete"), role: .destructive) {
                        HomeServerCodeStore.remove()
                        hasHomeServerCode = false
                        homeServerCheck = nil
                        Task { await viewModel.homeServerCodeChanged() }
                    }
                } message: {
                    Text(tr("הכתוביות יחזרו לזיהוי הדיבור בטלפון, עד שיסרקו שוב את קוד ה‑QR של המחשב.", "Captions go back to the phone’s speech recognition until the computer’s QR code is scanned again."))
                }
            }
        } header: {
            Text(tr("המחשב בבית", "Home computer"))
        } footer: {
            Text(tr("הדרך הקלה: מצלמת האייפון על קוד ה‑QR שהמחשב מציג, והכול מתמלא לבד. הקול נשלח למחשב שלכם, שכותב את הכתוביות ומחזיר אותן, רק בזמן שהכתוביות פועלות. באותה רשת Wi‑Fi כותבים את כתובת המחשב (למשל ‎192.168.1.20‎); מכל מקום אחר, כתובת שמתחילה ב‑wss://. הקוד נשמר רק בטלפון. כשאין חיבור למחשב, מודל ה‑Whisper שבטלפון ממשיך לבד.", "The easy way: point the iPhone’s Camera at the QR code the computer shows, and everything fills in by itself. The audio goes to your own computer, which writes the captions and sends them back, only while captions are on. On the same Wi‑Fi, enter the computer’s address (for example 192.168.1.20); from anywhere else, an address starting with wss://. The code is saved only on the phone. When the computer can’t be reached, the Whisper model on the phone carries on by itself."))
        }
    }

    @ViewBuilder
    private func homeServerCheckLabel(_ check: HomeServerCheck) -> some View {
        let text = Self.homeServerCheckText(check)
        switch check {
        case .connected:
            Label(text, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .codeRefused:
            Label(text, systemImage: "key.slash")
                .foregroundStyle(.red)
        case .unreachable:
            Label(text, systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
        case .notSetUp:
            Label(text, systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    static func homeServerCheckText(_ check: HomeServerCheck) -> String {
        switch check {
        case .connected(let milliseconds):
            tr("מחובר: המחשב ענה תוך \(milliseconds) אלפיות שנייה", "Connected: the computer answered in \(milliseconds) ms")
        case .codeRefused:
            tr("המחשב ענה, אבל לא קיבל את הקוד. סרקו שוב את קוד ה‑QR או הקלידו את הקוד מחדש.", "The computer answered but didn’t accept the code. Scan the QR code again or retype the code.")
        case .unreachable:
            tr("אין תשובה מהמחשב. בדקו שהוא דלוק ומחובר לאינטרנט.", "No answer from the computer. Check that it’s on and connected to the internet.")
        case .notSetUp:
            tr("חסרים כתובת או קוד", "The address or code is missing")
        }
    }

    private func saveHomeServerAddress() {
        let address = homeServerAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        homeServerAddressDraft = address
        homeServerCheck = nil
        Task { await viewModel.setHomeServerAddress(address) }
    }

    private func saveHomeServerCode() {
        let code = homeServerCodeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        let saved = HomeServerCodeStore.save(code)
        homeServerCodeSaveFailed = !saved
        guard saved else { return }
        homeServerCodeDraft = ""
        homeServerCheck = nil
        hasHomeServerCode = true
        Task { await viewModel.homeServerCodeChanged() }
    }

    private func saveCloudKey() {
        let key = cloudKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let saved = CloudKeyStore.save(key)
        cloudKeySaveFailed = !saved
        guard saved else { return }
        cloudKeyDraft = ""
        hasCloudKey = true
        Task { await viewModel.cloudKeyChanged() }
    }

    // MARK: - Language

    private var appLanguageBinding: Binding<AppLanguage> {
        Binding(
            get: { viewModel.settings.appLanguage },
            set: { viewModel.setAppLanguage($0) }
        )
    }

    private var languageSection: some View {
        Section {
            Picker(tr("שפת האפליקציה", "App language"), selection: appLanguageBinding) {
                Text(tr("כמו בטלפון", "Same as the phone")).tag(AppLanguage.system)
                Text("עברית").tag(AppLanguage.hebrew)
                Text("English").tag(AppLanguage.english)
            }
        } footer: {
            Text(tr("השפה של הכפתורים וההגדרות. הכתוביות נשארות בשפה שמדברים בה.", "The language of the buttons and settings. Captions stay in the language people speak."))
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                sliderLabelLayout {
                    Text(tr("גודל טקסט", "Text size"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(Int(viewModel.display.fontSize))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $viewModel.display.fontSize,
                    in: DisplayPreferences.minimumFontSize...DisplayPreferences.maximumFontSize,
                    step: 2
                ) {
                    Text(tr("גודל טקסט", "Text size"))
                } minimumValueLabel: {
                    Image(systemName: "textformat.size.smaller")
                } maximumValueLabel: {
                    Image(systemName: "textformat.size.larger")
                }
                .accessibilityValue("\(Int(viewModel.display.fontSize))")
                // With a number in it, so the number switch below shows
                // what it does right here.
                Text(
                    caption: tr("שלום סבתא, נגיע בשש עם שלושה ילדים.", "Hello grandma, we’ll arrive at six with three kids."),
                    emphasizingNumbers: viewModel.display.emphasizeNumbers,
                    size: viewModel.display.fontSize,
                    numberColor: CaptionTheme(viewModel.display.theme).numberText
                )
                    .font(.system(size: viewModel.display.fontSize, weight: viewModel.display.boldText ? .bold : .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(CaptionTheme(viewModel.display.theme).background, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(CaptionTheme(viewModel.display.theme).text)
            }

            themePicker

            Toggle(tr("טקסט מודגש", "Bold text"), isOn: $viewModel.display.boldText)
            Toggle(tr("להציג שמות דוברים", "Show speaker names"), isOn: $viewModel.display.showSpeakerNames)
            Toggle(tr("המסך לא נכבה בזמן האזנה", "Screen doesn’t turn off while listening"), isOn: $viewModel.display.keepScreenAwake)
            Toggle(tr("להסתיר את הכפתורים כשהכתוביות רצות", "Hide the buttons while captions are running"), isOn: $viewModel.display.autoHideControls)
            Toggle(tr("סימן שאלה ליד שורות שהמנוע לא בטוח בהן, ונקודות מתחת למילים שבספק", "Question mark next to lines the engine isn’t sure about, and dots under the doubtful words"), isOn: $viewModel.display.markUncertainLines)
            Toggle(tr("מספרים בולטים (שעות, כמויות, טלפונים)", "Bold numbers (times, amounts, phone numbers)"), isOn: $viewModel.display.emphasizeNumbers)
            Toggle(tr("כתוביות גם במסך הנעילה", "Captions on the lock screen too"), isOn: $viewModel.display.lockScreenCaptions)
            if viewModel.display.lockScreenCaptions && lockScreenBlocked {
                lockScreenBlockedNotice
            }
            Toggle(tr("VoiceOver מקריא שורות חדשות", "VoiceOver reads new lines aloud"), isOn: $viewModel.display.announceNewLines)
        } header: {
            Text(tr("תצוגה", "Display"))
        } footer: {
            Text(tr("סימן שאלה ליד שורה אומר שייתכן שהיא לא נשמעה נכון. מספרים כמו שעה, כמות כדורים או מספר טלפון מודגשים בצבע אחר, כדי שלא יתפספסו. לחיצה ארוכה על השורה מאפשרת לבקש שיחזרו עליה. כש-VoiceOver פועל, כל שורה שהסתיימה מוקראת או נשלחת לצג ברייל מעצמה. אחרי רבע שעה בלי דיבור המסך ננעל כרגיל, והכתוביות וההתראות ממשיכות. כשהכתוביות רצות לבד, הכפתורים למטה יורדים אחרי כמה שניות כדי לא להסתיר את השורה החדשה; נגיעה במסך מחזירה אותם. השורות האחרונות מופיעות גם במסך הנעילה, בלי לפתוח את הטלפון; מי שמסתכל על הטלפון יכול לקרוא אותן.", "A question mark next to a line means it may not have been heard correctly. Numbers like the time, a pill count, or a phone number are highlighted in another color so they aren’t missed. A long press on a line lets you ask for it to be repeated. When VoiceOver is on, every finished line is read aloud or sent to a braille display on its own. After a quarter hour without speech the screen locks as usual, and captions and alerts keep going. While captions are running on their own, the buttons at the bottom drop away after a few seconds so they don’t hide the new line; touching the screen brings them back. The last lines also appear on the lock screen without unlocking the phone; anyone looking at the phone can read them."))
        }
        .task(id: scenePhase) {
            // Again on coming back from the Settings app, as for notifications.
            guard scenePhase == .active else { return }
            lockScreenBlocked = !viewModel.lockScreenCaptionsAllowedBySystem
        }
    }

    private var lockScreenBlockedNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(tr("פעילויות בזמן אמת כבויות לאוזן בהגדרות הטלפון, אז הכתוביות לא יופיעו במסך הנעילה.", "Live Activities are turned off for Ozen in the phone’s settings, so captions won’t appear on the lock screen."), systemImage: "lock.slash.fill")
                .foregroundStyle(.red)
            Button(tr("לפתוח את הגדרות הטלפון", "Open the phone’s settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
        }
    }

    // MARK: - Alerts

    /// Sends a sample alert to the lock screen, so whoever sets the phone
    /// up sees for themselves that alerts get through.
    private var testNotificationButton: some View {
        Button {
            Task {
                guard await AlertNotifier.shared.requestAuthorization() else {
                    notificationsBlocked = true
                    return
                }
                AlertNotifier.shared.schedule(BackgroundAlertPolicy.testNotification, after: 10)
                testNotificationSent = true
            }
        } label: {
            if testNotificationSent {
                Label(tr("נשלחה. נעלו את הטלפון, ותוך 10 שניות היא תגיע", "Sent. Lock the phone, and it will arrive within 10 seconds"), systemImage: "checkmark")
            } else {
                Label(tr("לבדוק שהתראה מגיעה כשהטלפון נעול", "Test that an alert arrives when the phone is locked"), systemImage: "bell.and.waves.left.and.right")
            }
        }
    }

    private var alertsSection: some View {
        Section {
            NavigationLink {
                KeywordAlertsView(viewModel: viewModel)
            } label: {
                LabeledContent {
                    Text(viewModel.keywordAlerts.isEmpty ? tr("אין", "None") : "\(viewModel.keywordAlerts.filter(\.isEnabled).count)")
                        .foregroundStyle(.secondary)
                } label: {
                    Label(tr("מילים חשובות", "Important words"), systemImage: "text.badge.star")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("keywordAlertsRow")
            NavigationLink {
                SoundAlertsView(viewModel: viewModel)
            } label: {
                LabeledContent {
                    Text(viewModel.soundAlertPreferences.isEnabled ? SoundAlertsView.floorName(viewModel.soundAlertPreferences.minimumImportance) : tr("כבוי", "Off"))
                        .foregroundStyle(.secondary)
                } label: {
                    Label(tr("צלילים בבית", "Sounds at home"), systemImage: "bell.badge")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("soundAlertsRow")
            Toggle(isOn: Binding(
                get: { viewModel.notifyWhenInBackground },
                set: { enabled in
                    viewModel.notifyWhenInBackground = enabled
                    if enabled {
                        Task {
                            let allowed = await AlertNotifier.shared.requestAuthorization()
                            notificationsBlocked = !allowed
                        }
                    }
                }
            )) {
                Label(tr("התראה בטלפון כשהמסך כבוי", "Alert on phone when the screen is off"), systemImage: "iphone.radiowaves.left.and.right")
            }
            if viewModel.notifyWhenInBackground && !notificationsBlocked {
                testNotificationButton
            }
            if viewModel.notifyWhenInBackground && notificationsBlocked {
                VStack(alignment: .leading, spacing: 8) {
                    Label(tr("ההודעות של אוזן כבויות בהגדרות הטלפון, אז כשהמסך כבוי לא תגיע שום התראה.", "Ozen’s notifications are turned off in the phone’s settings, so no alert will arrive when the screen is off."), systemImage: "bell.slash.fill")
                        .foregroundStyle(.red)
                    Button(tr("לפתוח את הגדרות הטלפון", "Open the phone’s settings")) {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            openURL(url)
                        }
                    }
                }
            }
            if viewModel.notifyWhenInBackground {
                Toggle(isOn: Binding(
                    get: { viewModel.quietHours.isEnabled },
                    set: { enabled in
                        var hours = viewModel.quietHours
                        hours.isEnabled = enabled
                        viewModel.quietHours = hours
                    }
                )) {
                    Label(tr("שעות שקטות", "Quiet hours"), systemImage: "moon.zzz")
                }
                .accessibilityIdentifier("quietHoursToggle")
                if viewModel.quietHours.isEnabled {
                    Stepper(value: Binding(
                        get: { viewModel.quietHours.startHour },
                        set: { hour in
                            var hours = viewModel.quietHours
                            hours.startHour = hour
                            viewModel.quietHours = hours
                        }
                    ), in: 0...23) {
                        quietHoursRow(tr("מתחילות", "Starts"), hour: viewModel.quietHours.startHour)
                    }
                    Stepper(value: Binding(
                        get: { viewModel.quietHours.endHour },
                        set: { hour in
                            var hours = viewModel.quietHours
                            hours.endHour = hour
                            viewModel.quietHours = hours
                        }
                    ), in: 0...23) {
                        quietHoursRow(tr("מסתיימות", "Ends"), hour: viewModel.quietHours.endHour)
                    }
                    Text(tr("צלילים דחופים כמו אזעקה עדיין יתריעו.", "Urgent sounds like a siren still alert."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("quietHoursFootnote")
                }
            }
        } header: {
            Text(tr("התראות", "Alerts"))
        } footer: {
            Text(tr("רטט והדגשה כשנאמרת מילה חשובה; כרזה כשנשמע פעמון דלת, טלפון, אזעקה ועוד. כשהטלפון בכיס או נעול, אותן התראות מגיעות כהודעה בטלפון, וגם הודעה אם הכתוביות נעצרו ולא חזרו לבד. כדי שגם פנס המצלמה יהבהב בכל הודעה: הגדרות הטלפון ← נגישות ← שמע וחזותי ← הבהוב LED להתראות.", "Vibration and highlighting when an important word is said; a banner when a doorbell, phone, alarm, and more are heard. When the phone is in a pocket or locked, the same alerts arrive as a phone notification, plus a notification if captions stopped and didn’t come back on their own. For the camera flash to blink on every notification too: phone settings → Accessibility → Audio & Visual → LED Flash for Alerts."))
        }
        .task(id: scenePhase) {
            // Checked on opening and again on coming back from the
            // Settings app, where she may just have switched them on.
            guard scenePhase == .active else { return }
            notificationsBlocked = await AlertNotifier.shared.isAllowed() == false
        }
    }

    // MARK: - Speech

    private var speechSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                sliderLabelLayout {
                    Text(tr("מהירות דיבור", "Speech rate"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(String(format: "%.2f", viewModel.speechRate))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.speechRate, in: 0.2...0.7, step: 0.05)
                    .accessibilityLabel(tr("מהירות דיבור", "Speech rate"))
                    .accessibilityValue(String(format: "%.2f", viewModel.speechRate))
                sliderLabelLayout {
                    Text(tr("לאט", "Slow"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(tr("מהר", "Fast"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Button {
                viewModel.speak("שלום, זה קול הטלפון. ככה אני נשמע.")
            } label: {
                Label(tr("להשמיע דוגמה", "Play a sample"), systemImage: "speaker.wave.2")
            }
            if !viewModel.hasHebrewVoice {
                Text(tr("אין קול עברי מותקן. הוסיפו אחד בהגדרות המכשיר ← נגישות ← תוכן מדובר ← קולות ← עברית.", "No Hebrew voice is installed. Add one in the device settings → Accessibility → Spoken Content → Voices → Hebrew."))
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(tr("להגיד משהו (הקלדה לדיבור)", "Say something (type to speak)"))
        } footer: {
            Text(tr("הכתוביות מושהות בזמן שהטלפון מדבר, ומתחדשות לבד.", "Captions pause while the phone is speaking, and resume on their own."))
        }
    }

    // MARK: - History

    private var historySection: some View {
        Section {
            NavigationLink {
                HistoryView(viewModel: viewModel)
            } label: {
                Label(tr("שיחות קודמות", "Previous conversations"), systemImage: "clock.arrow.circlepath")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("historyRow")
        } header: {
            Text(tr("היסטוריה", "History"))
        } footer: {
            Text(viewModel.saveHistory ? tr("השיחות נשמרות בטלפון בלבד.", "Conversations are saved on the phone only.") : tr("שמירת שיחות כבויה.", "Saving conversations is off."))
        }
    }

    // MARK: - Vocabulary

    private var vocabularySection: some View {
        Section {
            NavigationLink {
                VocabularyView(viewModel: viewModel)
            } label: {
                HStack {
                    Label(tr("שמות ומילים מיוחדות", "Names and special words"), systemImage: "character.book.closed")
                    Spacer()
                    Text(viewModel.vocabulary.isEmpty ? tr("ריק", "Empty") : "\(viewModel.vocabulary.count)")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("vocabularyRow")
        } footer: {
            Text(tr("שני המנועים מקבלים את הרשימה כרמז, כדי ששמות של בני משפחה ייכתבו נכון.", "Both engines get the list as a hint, so family members’ names are spelled correctly."))
        }
    }

    // MARK: - Speakers

    private var speakersSection: some View {
        Section {
            ForEach(SavedSpeaker.grouping(viewModel.settings.speakerProfiles)) { speaker in
                Button {
                    renameText = speaker.name
                    renamingProfile = viewModel.settings.speakerProfiles.first { $0.name == speaker.name }
                } label: {
                    HStack {
                        Label(speaker.name, systemImage: "person.wave.2")
                        Spacer()
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityHint(tr("הקישו כדי לשנות את השם", "Tap to change the name"))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        pendingSpeakerRemoval = speaker.name
                    } label: {
                        Label(tr("מחיקה", "Delete"), systemImage: "trash")
                    }
                    .tint(.red)
                }
            }
            Button {
                showingEnrollment = true
            } label: {
                Label(tr("הוספת דובר", "Add speaker"), systemImage: "plus.circle")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("addSpeakerButton")
        } header: {
            Text(tr("דוברים שמורים", "Saved speakers"))
        } footer: {
            Text(tr("דובר שמור מזוהה בשמו מהמשפט הראשון. אפשר גם להקיש על שורה בכתוביות ולתת שם אחרי שהאדם כבר דיבר.", "A saved speaker is recognized by name from the first sentence. You can also tap a line in the captions and give a name after the person has already spoken."))
        }
    }

    // MARK: - Behaviour

    private var behaviourSection: some View {
        Section {
            Toggle(tr("רטט כשמישהו מתחיל לדבר אחרי שקט", "Vibrate when someone starts talking after silence"), isOn: $viewModel.hapticOnSpeechResume)

            VStack(alignment: .leading, spacing: 8) {
                sliderLabelLayout {
                    Text(tr("רגישות הפרדת דוברים", "Speaker separation sensitivity"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(String(format: "%.2f", viewModel.speakerSimilarityThreshold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityHidden(true)
                Slider(value: $viewModel.speakerSimilarityThreshold, in: 0.2...0.95, step: 0.01)
                    .accessibilityLabel(tr("רגישות הפרדת דוברים", "Speaker separation sensitivity"))
                    .accessibilityValue(String(format: "%.2f", viewModel.speakerSimilarityThreshold))
                sliderLabelLayout {
                    Text(tr("מאחד יותר", "More merging"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(tr("מפריד יותר", "More separating"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
        } header: {
            Text(tr("התנהגות", "Behavior"))
        } footer: {
            Text(tr("אם האפליקציה ממציאה \"דובר 3\" לאדם שכבר דיבר, הזיזו לכיוון \"מאחד יותר\". אם היא מאחדת שני אנשים, הזיזו לכיוון \"מפריד יותר\".", "If the app invents “Speaker 3” for someone who already spoke, move toward “More merging”. If it merges two people, move toward “More separating”."))
        }
    }

    // MARK: - Siri

    private var siriSection: some View {
        Section {
            SiriTipView(intent: StartCaptionsIntent())
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("״היי סירי, התחל כתוביות באוזן״", "Hey Siri, start captions in Ozen"))
                Text(tr("״היי סירי, עצור כתוביות באוזן״", "Hey Siri, stop captions in Ozen"))
                Text(tr("״היי סירי, תגיד באוזן שאני כבר באה״", "Hey Siri, tell Ozen I’m already on my way"))
            }
            .font(.callout)
            ShortcutsLink()
        } header: {
            Text(tr("סירי וקיצורי דרך", "Siri and shortcuts"))
        } footer: {
            if #available(iOS 18.0, *) {
                // The Control Center button (StartCaptionsControl) is only
                // found by someone who knows to look for it.
                Text(tr("הפקודות עובדות גם מהמסך הנעול, וגם באוטומציות של אפליקציית קיצורי דרך. יש גם כפתור ״התחלת כתוביות״ למרכז הבקרה או לתחתית המסך הנעול, במקום הפנס או המצלמה: לחיצה ארוכה על מקום ריק במרכז הבקרה, ואז חיפוש ״Ozen״.", "The commands also work from the lock screen, and in automations in the Shortcuts app. There’s also a “Start Captions” button for Control Center or the bottom of the lock screen, instead of the flashlight or camera: long-press an empty spot in Control Center, then search for “Ozen”."))
            } else {
                Text(tr("הפקודות עובדות גם מהמסך הנעול, וגם באוטומציות של אפליקציית קיצורי דרך.", "The commands also work from the lock screen, and in automations in the Shortcuts app."))
            }
        }
    }

    // MARK: - Maintenance

    private var maintenanceSection: some View {
        Section {
            NavigationLink {
                DiagnosticsView(viewModel: viewModel)
            } label: {
                Label(tr("אבחון", "Diagnostics"), systemImage: "stethoscope")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("diagnosticsRow")
            Button {
                confirmingWalkthrough = true
            } label: {
                Label(tr("להציג שוב את ההסבר הראשוני", "Show the initial walkthrough again"), systemImage: "questionmark.circle")
            }
            .confirmationDialog(tr("להציג שוב את ההסבר הראשוני?", "Show the initial walkthrough again?"), isPresented: $confirmingWalkthrough, titleVisibility: .visible) {
                Button(tr("להציג", "Show it")) {
                    viewModel.showOnboardingAgain()
                }
            } message: {
                Text(tr("הכתוביות ייעצרו עד סוף ההסבר.", "Captions stop until the walkthrough ends."))
            }
            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                Label(tr("ניקוי הכתוביות מהמסך", "Clear captions from the screen"), systemImage: "trash")
            }
        } header: {
            Text(tr("תחזוקה", "Maintenance"))
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent(tr("נוצר על ידי", "Made by"), value: viewModel.settings.creditLine)
            LabeledContent(tr("גרסה", "Version"), value: Self.versionString)
            if let expiresAt = InstallExpiryStatus.shared.expiresAt {
                // Installed with a free Apple ID: when it has to be
                // installed again, for whoever does that.
                LabeledContent(tr("ההתקנה תקפה עד", "Install valid until"), value: expiresAt.formatted(date: .abbreviated, time: .shortened))
            }
            Link(destination: URL(string: "https://github.com/arbel-source-org/ozen")!) {
                Label(tr("קוד המקור בגיטהאב", "Source code on GitHub"), systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Link(destination: URL(string: "https://github.com/argmaxinc/argmax-oss-swift")!) {
                Label(tr("WhisperKit (MIT) — מנוע Whisper", "WhisperKit (MIT) — Whisper engine"), systemImage: "shippingbox")
            }
        } header: {
            Text(tr("אודות", "About"))
        } footer: {
            Text(tr("אוזן היא תוכנה חופשית בקוד פתוח (MIT). כל העיבוד נעשה בטלפון; שום דבר לא נשלח החוצה אלא אם ביקשתם זאת במפורש למעלה.", "Ozen is free, open-source software (MIT). All processing happens on the phone; nothing is sent out unless you explicitly asked for it above."))
        }
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// At the largest text sizes the stepper leaves little room beside it:
    /// side by side, "Starts" broke mid-word and "22:00" split in two. The
    /// hour goes under the word there, and never wraps.
    private func quietHoursRow(_ title: String, hour: Int) -> some View {
        sliderLabelLayout {
            // One word: shrink a little rather than break it in the middle.
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            Text(Self.hourLabel(hour))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private static func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }
}
