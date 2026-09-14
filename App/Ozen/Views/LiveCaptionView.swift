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
    @State private var showingTypeToSpeak = false
    @State private var namingSegment: TranscriptSegment?
    @State private var isPinnedToBottom = true
    @State private var hapticTrigger = 0
    @State private var lastSegmentUpdate: TimeInterval = 0
    @State private var visibleSoundAlert: SoundAlert?
    @State private var visibleKeywordHit: KeywordHit?
    @State private var hasLaunched = false
    @State private var fontSizeTrigger = 0
    @State private var battery = BatteryMonitor()
    @State private var confirmingCellularDownload = false
    /// Live scale while a pinch is in progress; 1 otherwise.
    @GestureState private var pinchScale: Double = 1
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    /// With Reduce Motion on, new lines jump into view instead of sliding.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var theme: CaptionTheme { CaptionTheme(viewModel.display.theme) }

    /// The saved display settings with a pinch in progress applied, so the
    /// text grows under the fingers and only the final size is saved.
    private var liveDisplay: DisplayPreferences {
        var display = viewModel.display
        display.fontSize = DisplayPreferences.fontSize(display.fontSize, scaledBy: pinchScale)
        return display
    }

    private var pinchToResize: some Gesture {
        MagnifyGesture()
            .updating($pinchScale) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                let size = DisplayPreferences.fontSize(viewModel.display.fontSize, scaledBy: value.magnification)
                guard size != viewModel.display.fontSize else { return }
                viewModel.display.fontSize = size
                fontSizeTrigger += 1
            }
    }

    private var keepsScreenAwake: Bool {
        ScreenAwakePolicy.shouldKeepAwake(phase: viewModel.phase, keepAwakeWhileListening: viewModel.display.keepScreenAwake)
    }

    private var presentation: PhasePresentation {
        PhasePresentation(
            phase: viewModel.phase,
            engine: viewModel.pipeline.activeEngineKind,
            interruptedBySystem: viewModel.isInterruptedBySystem,
            scheduledRetry: viewModel.pipeline.scheduledRetry
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            theme.background.ignoresSafeArea()

            transcript
                .simultaneousGesture(pinchToResize)

            if pinchScale != 1 {
                Text("גודל טקסט \(Int(liveDisplay.fontSize))")
                    .font(.headline.monospacedDigit())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(theme.chrome)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if !isPinnedToBottom && !viewModel.segments.isEmpty {
                jumpToLatestPill
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            controlBar
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let notice = battery.notice {
                    BatteryBanner(notice: notice) {
                        withAnimation { battery.dismiss() }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let alert = visibleSoundAlert {
                    SoundAlertBanner(alert: alert) {
                        withAnimation { visibleSoundAlert = nil }
                        viewModel.dismissSoundAlert(id: alert.id)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let hit = visibleKeywordHit {
                    KeywordHitPill(hit: hit)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .preferredColorScheme(theme.colorScheme)
        .task(id: PendingAppAction.shared.serial) {
            // One hook for both the first appearance and every later Siri
            // request, so a request that launched the app is handled once
            // and in order. The work runs in its own task: a new request
            // changing `serial` cancels this closure, and that must not
            // cancel a model download that is halfway through.
            let pending = PendingAppAction.shared.take()
            let isFirstAppearance = !hasLaunched
            hasLaunched = true
            Task {
                if isFirstAppearance {
                    await viewModel.launch(pending: pending)
                } else if let pending {
                    await viewModel.perform(pending)
                }
            }
        }
        .onChange(of: viewModel.soundAlerts.last?.id) { _, _ in
            guard let alert = viewModel.soundAlerts.last else { return }
            withAnimation { visibleSoundAlert = alert }
        }
        .task(id: visibleSoundAlert?.id) {
            // Banners clear themselves; critical ones stay twice as long.
            guard let alert = visibleSoundAlert else { return }
            let seconds: UInt64 = alert.event.importance == .critical ? 16 : 8
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if visibleSoundAlert?.id == alert.id {
                withAnimation { visibleSoundAlert = nil }
            }
        }
        .onChange(of: viewModel.keywordHits.last?.id) { _, _ in
            guard let hit = viewModel.keywordHits.last else { return }
            withAnimation { visibleKeywordHit = hit }
        }
        .task(id: visibleKeywordHit?.id) {
            guard let hit = visibleKeywordHit else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if visibleKeywordHit?.id == hit.id {
                withAnimation { visibleKeywordHit = nil }
            }
        }
        .sensoryFeedback(.warning, trigger: viewModel.soundAlerts.last?.id)
        .sensoryFeedback(.success, trigger: viewModel.keywordHits.last?.id)
        .onChange(of: viewModel.phase) { _, _ in
            viewModel.historySessionDidChangePhase()
        }
        .onChange(of: viewModel.segments.count) { _, _ in
            noteSpeechActivity()
            // A new line whose text happens to equal the previous one ("כן",
            // then "כן" again) doesn't change the last line's text, so it
            // has to scroll here too or it lands below the fold.
            scrollToLatestIfPinned()
        }
        .onChange(of: viewModel.segments.last?.text) { _, _ in
            noteSpeechActivity()
            scrollToLatestIfPinned()
        }
        .onChange(of: viewModel.isListening, initial: true) { _, listening in
            battery.setActive(listening)
        }
        .onChange(of: keepsScreenAwake, initial: true) { _, keep in
            UIApplication.shared.isIdleTimerDisabled = keep
        }
        .sensoryFeedback(.warning, trigger: battery.notice?.id)
        .sensoryFeedback(.selection, trigger: fontSizeTrigger)
        .animation(.default, value: battery.notice)
        .onChange(of: scenePhase, initial: true) { _, phase in
            viewModel.sceneActivityChanged(isActive: phase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, case .failed = viewModel.phase {
                // Coming back from the system Settings app after granting
                // a permission: try again without making them tap.
                Task { await viewModel.retry() }
            }
            if phase == .background {
                viewModel.persistHistory(ended: false)
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: hapticTrigger)
        .sheet(isPresented: $showingMicPicker) {
            MicPickerView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingTypeToSpeak) {
            TypeToSpeakView(viewModel: viewModel)
        }
        .sheet(item: $namingSegment) { segment in
            NameSpeakerSheet(segment: segment, viewModel: viewModel)
        }
        .confirmationDialog(
            "להוריד את המודל בחבילת הגלישה?",
            isPresented: $confirmingCellularDownload,
            titleVisibility: .visible
        ) {
            Button("להוריד עכשיו") {
                Task { await viewModel.approveCellularDownload() }
            }
            Button("לחכות ל-Wi-Fi", role: .cancel) {}
        } message: {
            Text(cellularDownloadMessage)
        }
    }

    // MARK: - Transcript

    @State private var scrollProxy: ScrollViewProxy?

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: max(12, liveDisplay.fontSize * 0.6)) {
                    if viewModel.segments.isEmpty {
                        emptyState
                    }
                    ForEach(Array(viewModel.segments.enumerated()), id: \.element.id) { index, segment in
                        let name = viewModel.display.showSpeakerNames && segment.speakerClusterID != nil
                            ? viewModel.displayName(for: segment) : nil
                        CaptionRow(
                            segment: segment,
                            speakerName: name,
                            // Like a chat: the name heads a run of lines by
                            // one person instead of repeating on each.
                            showsSpeakerLabel: name != nil && CaptionLayout.showsSpeakerLabel(
                                for: segment,
                                after: index > 0 ? viewModel.segments[index - 1] : nil
                            ),
                            display: liveDisplay,
                            theme: theme,
                            isKeywordHit: viewModel.keywordHitSegmentIDs.contains(segment.id),
                            isStarred: viewModel.starredSegmentIDs.contains(segment.id),
                            isUncertain: viewModel.display.markUncertainLines && CaptionConfidence.isUncertain(segment)
                        )
                        .id(segment.id)
                        .onTapGesture { namingSegment = segment }
                        .contextMenu {
                            let starred = viewModel.starredSegmentIDs.contains(segment.id)
                            Button {
                                viewModel.toggleStar(segment)
                            } label: {
                                Label(starred ? "ביטול הסימון" : "סימון כחשוב", systemImage: starred ? "star.slash" : "star")
                            }
                            if viewModel.hasHebrewVoice {
                                Button {
                                    viewModel.askToRepeat()
                                } label: {
                                    Label("לבקש שיחזרו על זה", systemImage: "arrow.counterclockwise.circle")
                                }
                            }
                            Button {
                                namingSegment = segment
                            } label: {
                                Label("מי מדבר?", systemImage: "person.crop.circle.badge.questionmark")
                            }
                            Button {
                                UIPasteboard.general.string = segment.text
                            } label: {
                                Label("העתקה", systemImage: "doc.on.doc")
                            }
                        }
                        .accessibilityAction(named: viewModel.starredSegmentIDs.contains(segment.id) ? "ביטול הסימון" : "סימון כחשוב") {
                            viewModel.toggleStar(segment)
                        }
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
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.isListening ? "מקשיב." : "הכתוביות יופיעו כאן.")
                .font(.system(size: liveDisplay.fontSize, weight: .medium))
                .foregroundStyle(theme.text)
            Text(viewModel.isListening
                 ? "כשמישהו ידבר, המילים יופיעו כאן בזמן אמת. הקישו על שורה כדי לתת שם לדובר, לחצו עליה ארוכות כדי לסמן אותה כחשובה, וצבטו בשתי אצבעות כדי להגדיל או להקטין את הטקסט."
                 : "אפשר לבחור מיקרופון בכפתור למטה מימין ולשנות מנוע תמלול בהגדרות.")
                .font(.system(size: max(17, liveDisplay.fontSize * 0.6)))
                .foregroundStyle(theme.pendingText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        if animated && !reduceMotion {
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
        HStack(alignment: .center, spacing: 8) {
            micButton
            statusControl
                .frame(maxWidth: .infinity)
            typeToSpeakButton
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
            .frame(width: 56)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("בחירת מיקרופון")
    }

    private var typeToSpeakButton: some View {
        Button {
            showingTypeToSpeak = true
        } label: {
            VStack(spacing: 4) {
                Image(systemName: viewModel.isSpeaking ? "speaker.wave.3.fill" : "keyboard")
                    .font(.title2)
                Text("להגיד")
                    .font(.caption2)
            }
            .frame(width: 56)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("להגיד משהו בקול")
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
            .frame(width: 56)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("הגדרות")
    }

    private var statusControl: some View {
        let current = presentation
        return Button {
            perform(current.action)
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    if current.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(current.tint)
                    } else {
                        Image(systemName: current.systemImage)
                    }
                    Text(current.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(current.tint)

                if let detail = current.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                }

                if let progress = current.progress {
                    ProgressView(value: progress)
                        .tint(current.tint)
                        .frame(maxWidth: 160)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(current.action == .none)
        .accessibilityLabel(current.title)
        .accessibilityHint(current.detail ?? "")
    }

    private var cellularDownloadMessage: String {
        let megabytes = viewModel.phase.failure?.engineUnavailability?.downloadMegabytes ?? 0
        let size = megabytes > 0 ? "\(megabytes) MB" : "כמה מאות MB"
        return "המודל שוקל \(size). בחבילת גלישה זה יכול לעלות כסף או לגמור את נפח הגלישה. ב-Wi-Fi ההורדה תתחיל לבד."
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
        case .confirmCellularDownload:
            confirmingCellularDownload = true
        }
    }
}
