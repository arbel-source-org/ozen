import SwiftUI
import UIKit
import OzenKit

/// The whole point of the app: a full-screen, large-type, high-contrast
/// scrolling transcript. One persistent control row, no modals
/// interrupting an active conversation, and a status control that always
/// says exactly what the pipeline is doing — including the multi-minute
/// model download on first launch that the first build showed nothing for.
struct LiveCaptionView: View {
    @Bindable var viewModel: LiveCaptionViewModel
    @State private var showingMicPicker = false
    @State private var showingSettings = false
    @State private var namingSegment: TranscriptSegment?
    @State private var isPinnedToBottom = true
    @State private var hapticTrigger = 0
    @State private var lastSegmentUpdate: TimeInterval = 0
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    private var theme: CaptionTheme { CaptionTheme(viewModel.display.theme) }

    private var presentation: PhasePresentation {
        PhasePresentation(
            phase: viewModel.phase,
            engine: viewModel.pipeline.activeEngineKind,
            interruptedBySystem: viewModel.isInterruptedBySystem
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            theme.background.ignoresSafeArea()

            transcript

            if !isPinnedToBottom && !viewModel.segments.isEmpty {
                jumpToLatestPill
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            controlBar
        }
        .preferredColorScheme(theme.colorScheme)
        .task { await viewModel.start() }
        .onChange(of: viewModel.segments.count) { _, _ in noteSpeechActivity() }
        .onChange(of: viewModel.segments.last?.text) { _, _ in
            noteSpeechActivity()
            scrollToLatestIfPinned()
        }
        .onChange(of: viewModel.isListening, initial: true) { _, listening in
            UIApplication.shared.isIdleTimerDisabled = listening && viewModel.display.keepScreenAwake
        }
        .onChange(of: viewModel.display.keepScreenAwake) { _, keep in
            UIApplication.shared.isIdleTimerDisabled = viewModel.isListening && keep
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, case .failed = viewModel.phase {
                // Coming back from the system Settings app after granting
                // a permission: try again without making them tap.
                Task { await viewModel.retry() }
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: hapticTrigger)
        .sheet(isPresented: $showingMicPicker) {
            MicPickerView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: viewModel)
        }
        .sheet(item: $namingSegment) { segment in
            NameSpeakerSheet(segment: segment, viewModel: viewModel)
        }
    }

    // MARK: - Transcript

    @State private var scrollProxy: ScrollViewProxy?

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .trailing, spacing: max(12, viewModel.display.fontSize * 0.6)) {
                    if viewModel.segments.isEmpty {
                        emptyState
                    }
                    ForEach(viewModel.segments) { segment in
                        CaptionRow(
                            segment: segment,
                            speakerName: viewModel.display.showSpeakerNames ? viewModel.displayName(for: segment) : nil,
                            display: viewModel.display,
                            theme: theme
                        )
                        .id(segment.id)
                        .onTapGesture { namingSegment = segment }
                    }
                    // A sentinel at the very end: while it's on screen the
                    // reader is at the bottom and auto-scroll stays on;
                    // once they scroll up to re-read, it leaves and we
                    // stop yanking the view away from them.
                    Color.clear
                        .frame(height: 1)
                        .id("bottom-sentinel")
                        .onAppear { withAnimation { isPinnedToBottom = true } }
                        .onDisappear { withAnimation { isPinnedToBottom = false } }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 140)
            }
            .scrollIndicators(.hidden)
            .onAppear { scrollProxy = proxy }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Text(viewModel.isListening ? "מקשיב." : "הכתוביות יופיעו כאן.")
                .font(.system(size: viewModel.display.fontSize, weight: .medium))
                .foregroundStyle(theme.text)
            Text(viewModel.isListening
                 ? "כשמישהו ידבר, המילים יופיעו כאן בזמן אמת. הקישו על שורה כדי לתת שם לדובר."
                 : "אפשר לבחור מיקרופון בכפתור למטה מימין ולשנות מנוע תמלול בהגדרות.")
                .font(.system(size: max(17, viewModel.display.fontSize * 0.6)))
                .foregroundStyle(theme.pendingText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, 40)
    }

    private var jumpToLatestPill: some View {
        Button {
            isPinnedToBottom = true
            scrollToLatest(animated: true)
        } label: {
            Label("לשורה האחרונה", systemImage: "arrow.down.to.line")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.chrome)
    }

    private func scrollToLatestIfPinned() {
        guard isPinnedToBottom else { return }
        scrollToLatest(animated: true)
    }

    private func scrollToLatest(animated: Bool) {
        guard let proxy = scrollProxy else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("bottom-sentinel", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("bottom-sentinel", anchor: .bottom)
        }
    }

    /// A gentle buzz when speech starts again after a long quiet stretch —
    /// the reader may have looked away from the screen.
    private func noteSpeechActivity() {
        let now = Date().timeIntervalSince1970
        defer { lastSegmentUpdate = now }
        guard viewModel.hapticOnSpeechResume, lastSegmentUpdate > 0, now - lastSegmentUpdate > 8 else { return }
        hapticTrigger += 1
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(alignment: .center, spacing: 12) {
            micButton
            statusControl
                .frame(maxWidth: .infinity)
            settingsButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .foregroundStyle(theme.chrome)
    }

    private var micButton: some View {
        Button {
            showingMicPicker = true
        } label: {
            VStack(spacing: 4) {
                Image(systemName: MicPickerView.icon(for: viewModel.selectedInput?.portType ?? .other))
                    .font(.title2)
                Text(viewModel.selectedInput.map(MicPickerView.shortName) ?? "מיקרופון")
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(width: 64)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("בחירת מיקרופון")
    }

    private var settingsButton: some View {
        Button {
            showingSettings = true
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "gearshape")
                    .font(.title2)
                Text("הגדרות")
                    .font(.caption2)
            }
            .frame(width: 64)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("הגדרות")
    }

    private var statusControl: some View {
        let presentation = presentation
        return Button {
            perform(presentation.action)
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    if presentation.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(presentation.tint)
                    } else {
                        Image(systemName: presentation.systemImage)
                    }
                    Text(presentation.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(presentation.tint)

                if let detail = presentation.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                }

                if let progress = presentation.progress {
                    ProgressView(value: progress)
                        .tint(presentation.tint)
                        .frame(maxWidth: 160)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(presentation.action == .none)
        .accessibilityLabel(presentation.title)
        .accessibilityHint(presentation.detail ?? "")
    }

    private func perform(_ action: PhasePresentation.Action) {
        switch action {
        case .none:
            break
        case .start, .pause, .resume:
            Task { await viewModel.togglePause() }
        case .retry:
            Task { await viewModel.retry() }
        case .openSystemSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        case .openEngineSettings:
            showingSettings = true
        }
    }
}

/// One utterance. `isCommitted` drives the only visual difference that
/// matters here: committed text is solid and permanent, pending text is
/// dimmer and italic to signal "still settling" — nothing is ever
/// truncated in either state.
private struct CaptionRow: View {
    let segment: TranscriptSegment
    let speakerName: String?
    let display: DisplayPreferences
    let theme: CaptionTheme

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let speakerName {
                HStack(spacing: 6) {
                    Text(speakerName)
                        .font(.system(size: max(15, display.fontSize * 0.5), weight: .semibold))
                    Circle()
                        .frame(width: 10, height: 10)
                }
                .foregroundStyle(SpeakerColor.color(forClusterID: segment.speakerClusterID))
            }

            Text(segment.text)
                .font(.system(size: display.fontSize, weight: weight))
                .italic(!segment.isCommitted)
                .foregroundStyle(segment.isCommitted ? theme.text : theme.pendingText)
                .multilineTextAlignment(.trailing)
                .lineSpacing(display.fontSize * 0.15)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }

    private var weight: Font.Weight {
        if display.boldText { return .bold }
        return segment.isCommitted ? .medium : .regular
    }
}

private struct NameSpeakerSheet: View {
    let segment: TranscriptSegment
    let viewModel: LiveCaptionViewModel
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(segment.text)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } header: {
                    Text("מי אמר את זה?")
                }
                Section {
                    TextField("שם", text: $name)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text(segment.speakerClusterID == nil
                         ? "עדיין לא זוהה קול לשורה הזו. נסו שוב אחרי שהאדם ידבר עוד קצת."
                         : "מעכשיו כל מה שהקול הזה יגיד יופיע עם השם הזה.")
                }
            }
            .navigationTitle("שם לדובר")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("שמירה") {
                        viewModel.nameSpeaker(of: segment, name: name.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || segment.speakerClusterID == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("ביטול") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
