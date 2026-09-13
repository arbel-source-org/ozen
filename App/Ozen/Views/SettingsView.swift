import SwiftUI
import OzenKit

struct SettingsView: View {
    @Bindable var viewModel: LiveCaptionViewModel
    @State private var showingEnrollment = false
    @State private var confirmingClear = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                engineSection
                if viewModel.settings.engine == .whisperKit {
                    whisperModelSection
                } else {
                    appleSpeechSection
                }
                displaySection
                speakersSection
                behaviourSection
                maintenanceSection
                aboutSection
            }
            .navigationTitle("הגדרות")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("סגור") { dismiss() }
                }
            }
            .sheet(isPresented: $showingEnrollment) {
                SpeakerEnrollmentView(viewModel: viewModel)
            }
            .confirmationDialog("למחוק את כל הכתוביות מהמסך?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("מחיקה", role: .destructive) { viewModel.clearTranscript() }
                Button("ביטול", role: .cancel) {}
            }
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
            Picker("מנוע תמלול", selection: engineBinding) {
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
            Text("מנוע תמלול")
        } footer: {
            Text("שינוי המנוע מפעיל מחדש את ההאזנה. הכתוביות שכבר על המסך נשארות.")
        }
    }

    private func engineName(_ kind: TranscriptionEngineKind) -> String {
        switch kind {
        case .whisperKit: return "Whisper (במכשיר)"
        case .appleSpeech: return "זיהוי הדיבור של אפל"
        }
    }

    private func engineSummary(_ kind: TranscriptionEngineKind) -> String {
        switch kind {
        case .whisperKit: return "מודל קוד פתוח שרץ על הטלפון. עברית טובה, אפשר לבחור גודל מודל."
        case .appleSpeech: return "מובנה ב‑iOS. מהיר מאוד, אבל עברית במכשיר לא זמינה בכל גרסה."
        }
    }

    // MARK: - Whisper model

    private var whisperModelSection: some View {
        Section {
            NavigationLink {
                ModelManagerView(viewModel: viewModel)
            } label: {
                LabeledContent("מודל") {
                    Text(currentModelLabel)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Whisper")
        } footer: {
            Text("מודל גדול יותר מבין עברית טוב יותר אבל מגיב לאט יותר. \"Turbo (compressed)\" הוא הבחירה המומלצת לאייפון הזה.")
        }
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
            Toggle("לאפשר עיבוד בשרתי אפל", isOn: serverFallbackBinding)
        } header: {
            Text("זיהוי הדיבור של אפל")
        } footer: {
            Text("כבוי: הכול נשאר בטלפון. אם עברית במכשיר לא זמינה, המנוע פשוט לא יעבוד ותוצע חלופה. דולק: כשאין מודל עברית במכשיר, האודיו נשלח לשרתי אפל לזיהוי. זו החלטת פרטיות שלכם — האפליקציה אף פעם לא עושה את זה לבד.")
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("גודל טקסט")
                    Spacer()
                    Text("\(Int(viewModel.display.fontSize))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $viewModel.display.fontSize,
                    in: DisplayPreferences.minimumFontSize...DisplayPreferences.maximumFontSize,
                    step: 2
                ) {
                    Text("גודל טקסט")
                } minimumValueLabel: {
                    Image(systemName: "textformat.size.smaller")
                } maximumValueLabel: {
                    Image(systemName: "textformat.size.larger")
                }
                Text("שלום סבתא, מה שלומך היום?")
                    .font(.system(size: viewModel.display.fontSize, weight: viewModel.display.boldText ? .bold : .medium))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(12)
                    .background(CaptionTheme(viewModel.display.theme).background, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(CaptionTheme(viewModel.display.theme).text)
            }

            Picker("צבעים", selection: $viewModel.display.theme) {
                ForEach(DisplayPreferences.Theme.allCases, id: \.self) { theme in
                    Text(CaptionTheme.name(for: theme)).tag(theme)
                }
            }

            Toggle("טקסט מודגש", isOn: $viewModel.display.boldText)
            Toggle("להציג שמות דוברים", isOn: $viewModel.display.showSpeakerNames)
            Toggle("המסך לא נכבה בזמן האזנה", isOn: $viewModel.display.keepScreenAwake)
        } header: {
            Text("תצוגה")
        }
    }

    // MARK: - Speakers

    private var speakersSection: some View {
        Section {
            ForEach(viewModel.settings.speakerProfiles) { profile in
                Label(profile.name, systemImage: "person.wave.2")
            }
            .onDelete { offsets in
                for offset in offsets {
                    viewModel.removeProfile(id: viewModel.settings.speakerProfiles[offset].id)
                }
            }
            Button {
                showingEnrollment = true
            } label: {
                Label("הוספת דובר", systemImage: "plus.circle")
            }
        } header: {
            Text("דוברים שמורים")
        } footer: {
            Text("דובר שמור מזוהה בשמו מהמשפט הראשון. אפשר גם להקיש על שורה בכתוביות ולתת שם אחרי שהאדם כבר דיבר.")
        }
    }

    // MARK: - Behaviour

    private var behaviourSection: some View {
        Section {
            Toggle("רטט כשמישהו מתחיל לדבר אחרי שקט", isOn: $viewModel.hapticOnSpeechResume)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("רגישות הפרדת דוברים")
                    Spacer()
                    Text(String(format: "%.2f", viewModel.speakerSimilarityThreshold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.speakerSimilarityThreshold, in: 0.5...0.95, step: 0.01)
                HStack {
                    Text("מאחד יותר")
                    Spacer()
                    Text("מפריד יותר")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("התנהגות")
        } footer: {
            Text("אם האפליקציה ממציאה \"דובר 3\" לאדם שכבר דיבר, הזיזו שמאלה. אם היא מאחדת שני אנשים, הזיזו ימינה.")
        }
    }

    // MARK: - Maintenance

    private var maintenanceSection: some View {
        Section {
            NavigationLink {
                DiagnosticsView(viewModel: viewModel)
            } label: {
                Label("אבחון", systemImage: "stethoscope")
            }
            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                Label("ניקוי הכתוביות מהמסך", systemImage: "trash")
            }
        } header: {
            Text("תחזוקה")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("נוצר על ידי", value: viewModel.settings.creditLine)
            LabeledContent("גרסה", value: Self.versionString)
            Link(destination: URL(string: "https://github.com/arbelonson-source/ozen")!) {
                Label("קוד המקור בגיטהאב", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Link(destination: URL(string: "https://github.com/argmaxinc/WhisperKit")!) {
                Label("WhisperKit (MIT) — מנוע Whisper", systemImage: "shippingbox")
            }
        } header: {
            Text("אודות")
        } footer: {
            Text("אוזן היא תוכנה חופשית בקוד פתוח (MIT). כל העיבוד נעשה בטלפון; שום דבר לא נשלח החוצה אלא אם ביקשתם זאת במפורש למעלה.")
        }
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
