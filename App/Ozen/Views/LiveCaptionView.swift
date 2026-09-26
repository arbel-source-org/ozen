import SwiftUI
import UIKit
import OzenKit
import OzenPlatform

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
    @State private var confirmingClear = false
    @State private var namingSegment: TranscriptSegment?
    @State private var fixingWordFromSegment: TranscriptSegment?
    @State private var isPinnedToBottom = true
    /// Whether her finger is on the captions, or they're still coasting
    /// from a flick, and when that last ended. Only scrolling she does
    /// stops the captions following the newest line.
    @State private var userIsScrolling = false
    @State private var userScrollEndedAt: TimeInterval = 0
    /// The buttons at the bottom slide away while captions run on their
    /// own, so they don't cover the newest line (see `ControlBarAutoHide`).
    @State private var controlsHidden = false
    @State private var lastTouchAt = Date().timeIntervalSince1970
    @State private var controlBarHeight: CGFloat = 96
    /// How many lines there were when she scrolled up, so the way back down
    /// can say how many came since.
    @State private var lineCountWhenUnpinned = 0
    @State private var lastSegmentUpdate: TimeInterval = 0
    /// Advanced every half minute, so a long quiet can let the phone lock
    /// (see `ScreenAwakePolicy`) and the install-expiry warning appears on
    /// time.
    @State private var awakeClock = Date().timeIntervalSince1970
    @State private var visibleSoundAlert: SoundAlert?
    @State private var visibleKeywordHit: KeywordHit?
    @State private var hasLaunched = false
    @State private var fontSizeTrigger = 0
    @State private var battery = BatteryMonitor()
    private let installExpiry = InstallExpiryStatus.shared
    @State private var installExpiryDismissed = false
    /// What was typed on the big-letters pad opened by a Shortcut.
    @State private var bigText = ""
    @State private var showingBigText = false
    @State private var confirmingCellularDownload = false
    /// A saved conversation opened from this screen, and the line to open
    /// it at.
    @State private var openedConversation: OpenedConversation?
    @State private var showingNameAlertForm = false
    @State private var stopAnnouncer = CaptionsStopAnnouncer()
    /// Live scale while a pinch is in progress; 1 otherwise.
    @GestureState private var pinchScale: Double = 1
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    /// With Reduce Motion on, new lines jump into view instead of sliding.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// On an iPad, keeps caption lines and the control bar from stretching
    /// edge to edge, which otherwise makes lines too long to track by eye
    /// and pushes the buttons into the screen's far corners.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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
        ScreenAwakePolicy.shouldKeepAwake(
            phase: viewModel.phase,
            keepAwakeWhileListening: viewModel.display.keepScreenAwake,
            lastActivityAt: viewModel.lastCaptionActivityAt,
            now: max(awakeClock, viewModel.lastCaptionActivityAt ?? 0)
        )
    }

    /// When the install stops opening, while the screen should say so.
    private var installExpiryToWarn: Date? {
        guard !installExpiryDismissed, let expiresAt = installExpiry.expiresAt,
              InstallExpiry.shouldWarn(expiresAt: expiresAt, now: Date(timeIntervalSince1970: awakeClock))
        else { return nil }
        return expiresAt
    }

    private var presentation: PhasePresentation {
        PhasePresentation(
            phase: viewModel.phase,
            engine: viewModel.pipeline.activeEngineKind,
            interruptedBySystem: viewModel.isInterruptedBySystem,
            scheduledRetry: viewModel.pipeline.scheduledRetry,
            downloadSecondsRemaining: viewModel.pipeline.downloadSecondsRemaining,
            pausedForSpeech: viewModel.captionsHeldForSpeech,
            coveringForCloud: viewModel.pipeline.isCoveringForCloud,
            coveredEngine: viewModel.settings.engine,
            coverReason: viewModel.pipeline.coverReason
        )
    }

    /// How far the bottom of the transcript, and the "jump to latest"
    /// pill when it's showing, sit above the screen's bottom edge: the
    /// measured control bar's height while it's visible, or just enough
    /// for the small reveal handle once it's hidden. The two used to
    /// disagree — the pill kept the full control-bar gap even once the
    /// bar itself had slid away, leaving it floating with an empty stretch
    /// of screen under it instead of sitting near the handle.
    private var reservedBottomSpace: CGFloat {
        controlsHidden ? 56 : controlBarHeight + 16
    }

    /// A conversation with more lines than fit on screen, pinned to the
    /// newest one, always has an oldest visible line scrolling out past
    /// the top edge — the same as any chat app with no separate top bar.
    /// At the largest text size that line can reach the status bar before
    /// it's gone, so this fades it to the background colour first rather
    /// than letting it collide with the clock and battery icons.
    private var topScrollFade: some View {
        LinearGradient(colors: [theme.background, theme.background.opacity(0)], startPoint: .top, endPoint: .bottom)
            .frame(height: 90)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The screen itself: captions, banners and the control bar.
    private var screen: some View {
        ZStack(alignment: .bottom) {
            transcript
                .simultaneousGesture(pinchToResize)

            if pinchScale != 1 {
                Text(tr("גודל טקסט \(Int(liveDisplay.fontSize))", "Text size \(Int(liveDisplay.fontSize))"))
                    .font(.headline.monospacedDigit())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .ozenGlass(in: Capsule())
                    .foregroundStyle(theme.chrome)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if !isPinnedToBottom && !viewModel.segments.isEmpty {
                jumpToLatestPill
                    .padding(.bottom, reservedBottomSpace)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            hidingControlBar

            if controlsHidden {
                showControlsButton
                    .transition(.opacity)
            }

            topScrollFade
        }
        // A modifier, not a ZStack layer: a plain sibling that ignores the
        // safe area expands the whole ZStack's proposed size for every
        // other child too. `.background()` sizes itself to the real
        // content instead, so only this one layer spills past it.
        .background(theme.background.ignoresSafeArea())
        // Without this, the idle clock starts at this view's own init,
        // which can run measurably before she can actually see the
        // screen (permission prompts, a model still loading). If the
        // first caption line only lands after that head start already
        // used up the idle window, the bar could vanish the instant it
        // appears, before she's had any chance to see or use it.
        .onAppear { revealControls() }
        .simultaneousGesture(TapGesture().onEnded { revealControls() })
        .task(id: viewModel.isListening) {
            while !Task.isCancelled {
                updateControlsVisibility()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let expiresAt = installExpiryToWarn {
                    InstallExpiryBanner(expiresAt: expiresAt, now: Date(timeIntervalSince1970: awakeClock)) {
                        withAnimation { installExpiryDismissed = true }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if viewModel.savingTrouble.shouldShow {
                    SavingTroubleBanner {
                        withAnimation { viewModel.dismissSavingTrouble() }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
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
                    KeywordHitPill(hit: hit, speakerName: viewModel.speakerName(for: hit))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                awayJumpButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .overlay {
            // Removed rather than fed nil while covered, so closing the
            // covering screen doesn't replay the last flash.
            if !isCoveredByAlertScreen {
                AlertFlashOverlay(alert: viewModel.soundAlerts.last)
            }
        }
        .preferredColorScheme(theme.colorScheme)
    }

    /// Everything that reacts to what happens: Siri requests, alerts,
    /// new lines, the phase and the app coming and going.
    private var reactingScreen: some View {
        screen
        .task(id: PendingAppAction.shared.serial) {
            // One hook for both the first appearance and every later Siri
            // request, so a request that launched the app is handled once
            // and in order. The work runs in its own task: a new request
            // changing `serial` cancels this closure, and that must not
            // cancel a model download that is halfway through.
            let pending = PendingAppAction.shared.takeAll()
            let isFirstAppearance = !hasLaunched
            hasLaunched = true
            guard isFirstAppearance || !pending.isEmpty else { return }
            Task {
                await viewModel.handle(pending: pending, isFirstAppearance: isFirstAppearance)
            }
        }
        .onChange(of: viewModel.soundAlerts.last?.id) { _, _ in
            guard let alert = viewModel.soundAlerts.last else { return }
            if !isCoveredByAlertScreen, alert.takesBanner(from: visibleSoundAlert) {
                withAnimation { visibleSoundAlert = alert }
            }
            vibrate(.pattern(for: alert.event.importance))
            announceAlert(alert.event.importance == .critical ? tr("שימו לב! \(alert.event.name)", "Attention! \(alert.event.name)") : tr("התראה: \(alert.event.name)", "Alert: \(alert.event.name)"))
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
            // Every line with the word keeps its highlight; the buzz, pill
            // and announcement don't repeat for each mention at the table.
            guard let hit = viewModel.claimAttentionForNewKeywordHits() else { return }
            if !isCoveredByAlertScreen {
                withAnimation { visibleKeywordHit = hit }
            }
            vibrate(.keyword)
            announceAlert(tr("נאמר: \(hit.match.phrase)", "Said: \(hit.match.phrase)"))
        }
        .task(id: visibleKeywordHit?.id) {
            guard let hit = visibleKeywordHit else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if visibleKeywordHit?.id == hit.id {
                withAnimation { visibleKeywordHit = nil }
            }
        }
        .onChange(of: viewModel.phase.step) { _, phase in
            announceStopOrReturn(phase)
            updateControlsVisibility()
        }
        .onChange(of: isPinnedToBottom) { _, _ in
            updateControlsVisibility()
        }
        .onChange(of: viewModel.segments.count) { _, _ in
            noteSpeechActivity()
            // A new line whose text happens to equal the previous one ("yes",
            // then "yes" again) doesn't change the last line's text, so it
            // has to scroll here too or it lands below the fold.
            scrollToLatestIfPinned()
        }
        .onChange(of: viewModel.segments.last?.text) { _, _ in
            noteSpeechActivity()
            scrollToLatestIfPinned()
        }
        .onChange(of: viewModel.committedLineCount) { _, _ in
            announceNewLines()
        }
        .onChange(of: viewModel.segments.isEmpty) { _, _ in
            announceNewLines()
        }
        .onChange(of: viewModel.isListening, initial: true) { _, listening in
            battery.onWarning = { [viewModel] warning in
                viewModel.batteryWarningRaised(warning)
            }
            battery.setActive(listening)
        }
        .onChange(of: keepsScreenAwake, initial: true) { _, keep in
            UIApplication.shared.isIdleTimerDisabled = keep
        }
        .task(id: viewModel.isListening) {
            // Ticks whether or not captions run: the screen lock needs it
            // while listening, and the install-expiry warning must still
            // appear on a screen left paused or failed for a day.
            while !Task.isCancelled {
                awakeClock = Date().timeIntervalSince1970
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .sensoryFeedback(.warning, trigger: battery.notice?.id)
        .sensoryFeedback(.selection, trigger: fontSizeTrigger)
        .animation(.default, value: battery.notice)
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Inactive is Control Center pulled down, a call banner, or the
            // moment on the way to locking: the captions are still on
            // screen, or about to be put away, which background will say.
            // Counting it as away posted phone notifications over an app
            // she was looking at.
            guard phase != .inactive else { return }
            viewModel.sceneActivityChanged(isActive: phase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // The clock may have slept with the app; and a dismissed
                // expiry warning comes back each time the app is opened.
                awakeClock = Date().timeIntervalSince1970
                installExpiryDismissed = false
            }
            if phase == .active, case .failed(let failure) = viewModel.phase,
               failure.engineUnavailability?.kind != .notEnoughStorage {
                // Coming back from the system Settings app after granting
                // a permission: try again without making them tap. A full
                // phone is rechecked by the view model, which only retries
                // once there is room.
                Task { await viewModel.retry() }
            }
            if phase == .background {
                viewModel.persistHistory(ended: false)
            }
        }
    }

    var body: some View {
        reactingScreen
        .sheet(item: $openedConversation) { opened in
            NavigationStack {
                HistoryDetailView(viewModel: viewModel, sessionID: opened.id, initialLineID: opened.lineID) {
                    // Renamed or deleted from inside: the card follows.
                    Task { await viewModel.loadRecentConversation() }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(tr("סגירה", "Close")) { openedConversation = nil }
                    }
                }
            }
        }
        .sheet(isPresented: $showingMicPicker) {
            MicPickerView(viewModel: viewModel)
                .alertOverlay(for: viewModel)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: viewModel)
                .alertOverlay(for: viewModel)
        }
        .sheet(isPresented: $showingTypeToSpeak) {
            TypeToSpeakView(viewModel: viewModel)
                .alertOverlay(for: viewModel)
        }
        .onChange(of: viewModel.isShowingBigText, initial: true) { _, asked in
            if asked { presentBigText() }
        }
        .fullScreenCover(isPresented: $showingBigText) {
            BigTextView(
                text: $bigText,
                display: viewModel.display,
                canSpeak: viewModel.hasHebrewVoice,
                onSpeak: { viewModel.speak($0) }
            )
            .alertOverlay(for: viewModel)
        }
        .sheet(item: $namingSegment) { segment in
            NameSpeakerSheet(segment: segment, viewModel: viewModel)
        }
        .sheet(item: $fixingWordFromSegment) { segment in
            FixVocabularyWordSheet(segment: segment, viewModel: viewModel)
        }
        .confirmationDialog(
            tr("להוריד את המודל בחבילת הגלישה?", "Download the model over cellular data?"),
            isPresented: $confirmingCellularDownload,
            titleVisibility: .visible
        ) {
            Button(tr("להוריד עכשיו", "Download now")) {
                Task { await viewModel.approveCellularDownload() }
            }
            Button(tr("לחכות ל-Wi-Fi", "Wait for Wi‑Fi"), role: .cancel) {}
        } message: {
            Text(cellularDownloadMessage)
        }
        .confirmationDialog(
            tr("למחוק את כל הכתוביות מהמסך?", "Delete all captions from the screen?"),
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button(tr("מחיקה", "Delete"), role: .destructive) { viewModel.clearTranscript() }
            Button(tr("ביטול", "Cancel"), role: .cancel) {}
        } message: {
            Text(viewModel.settings.saveHistory
                 ? tr("השמירה בהיסטוריה לא עובדת כרגע, ולכן הן לא יישמרו.", "Saving to History isn't working right now, so they won't be saved.")
                 : tr("היסטוריית השיחות כבויה, ולכן הן לא יישמרו.", "History is off, so they won't be saved."))
        }
    }

    private var clearKeepsHistory: Bool {
        viewModel.settings.saveHistory && viewModel.historySaveFailure == nil
    }

    // MARK: - Transcript

    @State private var scrollProxy: ScrollViewProxy?
    @State private var showingProblemMarked = false

    private var transcript: some View {
        transcriptScroll
            // Here rather than on the offer card: the card goes as soon as
            // the first caption line arrives, and would take the sheet
            // with it. Its own expression: the list is already near what
            // the type checker manages in one.
            .sheet(isPresented: $showingNameAlertForm) {
                NameAlertSheet(viewModel: viewModel)
                    .alertOverlay(for: viewModel)
            }
            .alert(tr("הבעיה סומנה", "Problem marked"), isPresented: $showingProblemMarked) {
                Button(tr("אישור", "OK"), role: .cancel) {}
            } message: {
                Text(tr("מה שרץ עכשיו והשורות האחרונות נשמרו בטלפון בלבד. כדי לשלוח אותם למי שעוזר לך: הגדרות ← אבחון ← שליחת הדוח.", "What was running and the last few lines were saved, on the phone only. To send them to whoever helps you: Settings → Diagnostics → Send report."))
            }
    }

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: max(12, liveDisplay.fontSize * 0.6)) {
                    if viewModel.segments.isEmpty {
                        emptyState
                    } else if CaptionLayout.firstOnScreenIndex(lineCount: viewModel.segments.count) > 0 {
                        earlierLinesNote
                    }
                    let mark = awayMark
                    ForEach(onScreenLines, id: \.segment.id) { index, segment in
                        transcriptRow(index: index, segment: segment, awayMark: mark)
                    }
                    // A sentinel at the very end: while it's on screen the
                    // reader is at the bottom and auto-scroll stays on;
                    // once they scroll up to re-read, it leaves and we
                    // stop yanking the view away from them.
                    // Room for the buttons above it, so following the
                    // newest line keeps that line clear of them.
                    Color.clear
                        .frame(height: reservedBottomSpace)
                    Color.clear
                        .frame(height: 1)
                        .id("bottom-sentinel")
                        .onAppear { withAnimation { isPinnedToBottom = true } }
                        .onDisappear {
                            // A line growing, or the scroll animation itself,
                            // also moves this out of view for a moment; that
                            // used to stop the captions following part way.
                            guard userIsScrolling || Date().timeIntervalSince1970 - userScrollEndedAt < 1 else { return }
                            lineCountWhenUnpinned = viewModel.segments.count
                            withAnimation { isPinnedToBottom = false }
                        }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .frame(maxWidth: horizontalSizeClass == .regular ? 800 : .infinity)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("transcriptScroll")
            }
            .scrollIndicators(.hidden)
            .onUserScroll { scrolling in
                if scrolling {
                    revealControls()
                } else if userIsScrolling {
                    userScrollEndedAt = Date().timeIntervalSince1970
                }
                userIsScrolling = scrolling
            }
            .onAppear { scrollProxy = proxy }
        }
    }

    /// One caption line with everything a hold or a tap on it can do.
    private func captionLine(index: Int, segment: TranscriptSegment) -> some View {
        let name = viewModel.display.showSpeakerNames && segment.speakerClusterID != nil
            ? viewModel.displayName(for: segment) : nil
        return CaptionRow(
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
            isUncertain: viewModel.display.markUncertainLines && CaptionConfidence.isUncertain(segment),
            marksUncertainWords: viewModel.display.markUncertainLines
        )
        .id(segment.id)
        // No plain-tap action: a finger brushing the text while reading, or
        // handing the phone over, used to open the naming sheet and its
        // keyboard mid-conversation. Naming lives in the hold menu below.
        .contextMenu {
            let starred = viewModel.starredSegmentIDs.contains(segment.id)
            Button {
                viewModel.toggleStar(segment)
            } label: {
                Label(starred ? tr("ביטול הסימון", "Remove mark") : tr("סימון כחשוב", "Mark as important"), systemImage: starred ? "star.slash" : "star")
            }
            if viewModel.hasHebrewVoice {
                Button {
                    viewModel.askToRepeat()
                } label: {
                    Label(tr("לבקש שיחזרו על זה", "Ask them to repeat that"), systemImage: "arrow.counterclockwise.circle")
                }
            }
            Button {
                namingSegment = segment
            } label: {
                Label(tr("מי מדבר?", "Who is speaking?"), systemImage: "person.crop.circle.badge.questionmark")
            }
            Button {
                fixingWordFromSegment = segment
            } label: {
                Label(tr("תיקון מילה למילון", "Fix a word for next time"), systemImage: "text.badge.checkmark")
            }
            Button {
                UIPasteboard.general.string = segment.text
            } label: {
                Label(tr("העתקה", "Copy"), systemImage: "doc.on.doc")
            }
            if let saved = viewModel.savedConversationID(holdingLineAt: index) {
                Button {
                    viewModel.persistHistory(ended: false)
                    openedConversation = OpenedConversation(id: saved, lineID: segment.id)
                } label: {
                    Label(tr("פתיחת השיחה כולה, לשיתוף או לחיפוש", "Open the whole conversation, to share or search"), systemImage: "square.and.arrow.up")
                }
            }
            Button {
                viewModel.markProblem()
                showingProblemMarked = true
            } label: {
                Label(tr("הכתוביות לא טובות? לסמן בעיה", "Captions not good? Mark a problem"), systemImage: "exclamationmark.bubble")
            }
        }
        .accessibilityActions {
            Button(viewModel.starredSegmentIDs.contains(segment.id) ? tr("ביטול הסימון", "Remove mark") : tr("סימון כחשוב", "Mark as important")) {
                viewModel.toggleStar(segment)
            }
            if viewModel.hasHebrewVoice {
                Button(tr("לבקש שיחזרו על זה", "Ask them to repeat that")) {
                    viewModel.askToRepeat()
                }
            }
            Button(tr("מי מדבר?", "Who is speaking?")) {
                namingSegment = segment
            }
            Button(tr("תיקון מילה למילון", "Fix a word for next time")) {
                fixingWordFromSegment = segment
            }
        }
    }

    /// Where the lines said while the screen was away begin, as drawn (see
    /// `AwayCatchUp.drawnMarkIndex`). It scans the whole transcript, so the
    /// list reads it once per update rather than once per line.
    private var awayMark: (index: Int, segmentID: UUID, count: Int)? {
        let segments = viewModel.segments
        guard let index = viewModel.awayCatchUp.drawnMarkIndex(
            in: segments,
            firstDrawnIndex: CaptionLayout.firstOnScreenIndex(lineCount: segments.count)
        ) else { return nil }
        return (index, segments[index].id, viewModel.awayCatchUp.missedLineCount(in: segments))
    }

    /// A caption line, with what goes above it: the mark where the lines
    /// said while she was away begin, or the time after a quiet stretch.
    @ViewBuilder
    private func transcriptRow(index: Int, segment: TranscriptSegment, awayMark: (index: Int, segmentID: UUID, count: Int)?) -> some View {
        let previous = index > 0 ? viewModel.segments[index - 1] : nil
        if let awayMark, index == awayMark.index {
            awayDivider(lineCount: awayMark.count)
        } else if let previous, CaptionLayout.startsAfterQuiet(segment, previous: previous) {
            quietGapDivider(from: previous, to: segment)
        }
        captionLine(index: index, segment: segment)
    }

    /// The clock time the conversation picked up again, with the day when
    /// it isn't the same one.
    private func quietGapDivider(from previous: TranscriptSegment, to segment: TranscriptSegment) -> some View {
        let start = Date(timeIntervalSince1970: segment.startTimestamp)
        let sameDay = Calendar.current.isDate(start, inSameDayAs: Date(timeIntervalSince1970: previous.lastUpdateTimestamp))
        let time = start.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened)
        return HStack(spacing: 10) {
            Rectangle()
                .fill(theme.pendingText.opacity(0.5))
                .frame(height: 1)
            Text(time)
                .font(.system(size: max(15, liveDisplay.fontSize * 0.45), weight: .medium))
                .monospacedDigit()
                .foregroundStyle(theme.pendingText)
                .fixedSize(horizontal: true, vertical: true)
            Rectangle()
                .fill(theme.pendingText.opacity(0.5))
                .frame(height: 1)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("אחרי הפסקה, מהשעה \(time)", "After a break, from \(time)"))
    }

    private func awayDivider(lineCount: Int) -> some View {
        HStack(spacing: 10) {
            Text(tr("נאמר כשהאפליקציה הייתה סגורה · \(ConversationStats.linesText(lineCount))", "Said while the app was closed · \(ConversationStats.linesText(lineCount))"))
                .font(.system(size: max(15, liveDisplay.fontSize * 0.5), weight: .semibold))
                .foregroundStyle(theme.pendingText)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle()
                .fill(theme.pendingText)
                .frame(height: 2)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("מכאן, מה שנאמר כשהאפליקציה הייתה סגורה: \(ConversationStats.linesText(lineCount))", "From here, what was said while the app was closed: \(ConversationStats.linesText(lineCount))"))
        // On screen, it has been seen: no need to offer the jump.
        .onAppear { viewModel.acknowledgeAwayLines() }
    }

    /// Back at the newest line after a while away, a way up to where the
    /// lines she missed begin. Shown until she goes there or sees the mark.
    @ViewBuilder
    private var awayJumpButton: some View {
        if let mark = awayMark, viewModel.awayCatchUp.offersJump(in: viewModel.segments) {
            Button {
                viewModel.acknowledgeAwayLines()
                lineCountWhenUnpinned = viewModel.segments.count
                isPinnedToBottom = false
                guard let proxy = scrollProxy else { return }
                // The mark sits just above its first line: leave room for it.
                let anchor = UnitPoint(x: 0.5, y: 0.12)
                if reduceMotion {
                    proxy.scrollTo(mark.segmentID, anchor: anchor)
                } else {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(mark.segmentID, anchor: anchor)
                    }
                }
            } label: {
                Label(tr("מה שנאמר בינתיים · \(ConversationStats.linesText(mark.count))", "What was said meanwhile · \(ConversationStats.linesText(mark.count))"), systemImage: "arrow.up.to.line")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    // A target a shaky finger finds at any text size.
                    .frame(minHeight: 48)
                    .ozenGlass(in: Capsule(), interactive: true, fallback: .thinMaterial)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.chrome)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// The newest lines (see `CaptionLayout.onScreenLineLimit`), each with
    /// its place in the whole transcript: the speaker label looks at the
    /// line before it, even the first one drawn.
    private var onScreenLines: [(index: Int, segment: TranscriptSegment)] {
        let segments = viewModel.segments
        let start = CaptionLayout.firstOnScreenIndex(lineCount: segments.count)
        return segments.indices.dropFirst(start).map { ($0, segments[$0]) }
    }

    /// Above the first line drawn, once the oldest ones are no longer:
    /// one tap opens the saved conversation at the last line that went.
    @ViewBuilder
    private var earlierLinesNote: some View {
        let lastHidden = CaptionLayout.firstOnScreenIndex(lineCount: viewModel.segments.count) - 1
        if let saved = viewModel.savedConversationID(holdingLineAt: lastHidden) {
            let lineID = viewModel.segments[lastHidden].id
            Button {
                viewModel.persistHistory(ended: false)
                openedConversation = OpenedConversation(id: saved, lineID: lineID)
            } label: {
                Label(tr("שורות מוקדמות יותר נשמרו. הקישו כדי לקרוא אותן", "Earlier lines were saved. Tap to read them"), systemImage: "text.bubble")
                    .font(.system(size: max(15, liveDisplay.fontSize * 0.5), weight: .semibold))
                    .foregroundStyle(theme.chrome)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Text(tr("שורות מוקדמות יותר כבר לא מוצגות", "Earlier lines are no longer shown"))
                .font(.system(size: max(15, liveDisplay.fontSize * 0.5)))
                .foregroundStyle(theme.pendingText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.isListening ? tr("מקשיב.", "Listening.") : tr("הכתוביות יופיעו כאן.", "Captions will appear here."))
                .font(.system(size: liveDisplay.fontSize, weight: .medium))
                .foregroundStyle(theme.text)
            Text(viewModel.isListening
                 ? tr("כשמישהו ידבר, המילים יופיעו כאן בזמן אמת. לחצו ארוכות על שורה כדי לסמן אותה כחשובה או לתת שם לדובר, וצבטו בשתי אצבעות כדי להגדיל או להקטין את הטקסט.", "When someone talks, the words will appear here in real time. Press and hold a line to mark it as important or name the speaker, and pinch with two fingers to make the text bigger or smaller.")
                 : tr("אפשר לבחור מיקרופון בכפתור למטה מימין ולשנות מנוע תמלול בהגדרות.", "You can choose a microphone with the button at the bottom right, and change the transcription engine in Settings."))
                .font(.system(size: max(17, liveDisplay.fontSize * 0.6)))
                .foregroundStyle(theme.pendingText)
                .fixedSize(horizontal: false, vertical: true)
            // Ahead of the recent conversation: a phone that always has one
            // would otherwise never be told its model is the weak one.
            let better = viewModel.settings.offersBetterModel() ? betterModelOption : nil
            if let better {
                betterModelOfferCard(better)
                    .padding(.top, 8)
            }
            if let recent = viewModel.recentConversation {
                recentConversationCard(recent)
                    .padding(.top, 8)
            } else if better == nil, viewModel.settings.offersNameAlert {
                nameAlertOfferCard
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 40)
    }

    /// The recommended model, when it is worth offering here: a phone too
    /// full for the download would only be sent to a status line saying so,
    /// and the model list already says how much room it needs.
    private var betterModelOption: WhisperModelOption? {
        guard let option = WhisperModelCatalog.option(for: WhisperModelCatalog.recommendedVariant) else { return nil }
        let fits = StorageSpaceGate.shortfallMegabytes(downloadMegabytes: option.installMegabytes, availableBytes: DeviceStorage.availableBytes()) == nil
        return fits ? option : nil
    }

    /// For a phone set up when Small was the default model: most Hebrew
    /// words came out wrong, and the fix is one download away.
    private func betterModelOfferCard(_ option: WhisperModelOption) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                Task { await viewModel.acceptBetterModelOffer() }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("עברית מדויקת בהרבה עם מודל אחר", "Much more accurate Hebrew with a different model"))
                            .font(.headline)
                        Text(tr("הקישו כדי להוריד \(option.displayName), \(option.sizeLabel), פעם אחת ב-Wi-Fi", "Tap to download \(option.displayName), \(option.sizeLabel), once over Wi-Fi"))
                            .font(.subheadline.weight(.semibold))
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                withAnimation { viewModel.dismissBetterModelOffer() }
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("לא עכשיו", "Not now"))
        }
        .foregroundStyle(theme.chrome)
        .padding(14)
        .background(theme.chrome.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    /// For a phone set up before the walkthrough asked for her name: the
    /// buzz for her name only works once the name is in.
    private var nameAlertOfferCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                showingNameAlertForm = true
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "bell.and.waves.left.and.right")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("שהטלפון ירטוט כשקוראים לך?", "Have the phone buzz when someone calls your name?"))
                            .font(.headline)
                        Text(tr("הקישו כדי לכתוב את השם שלך", "Tap to write your name"))
                            .font(.subheadline.weight(.semibold))
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                withAnimation { viewModel.dismissNameAlertOffer() }
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("לא עכשיו", "Not now"))
        }
        .foregroundStyle(theme.chrome)
        .padding(14)
        .background(theme.chrome.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    /// After iOS closed the app in the middle of a conversation: what was
    /// said before is one tap away instead of gone from view.
    private func recentConversationCard(_ recent: TranscriptSessionSummary) -> some View {
        let minutes = RecentConversation.minutesAgo(recent, now: Date().timeIntervalSince1970)
        return HStack(alignment: .top, spacing: 12) {
            Button {
                openedConversation = OpenedConversation(id: recent.id)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "text.bubble")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("השיחה מ\(Self.minutesAgoText(minutes)) נשמרה", "The conversation from \(Self.minutesAgoText(minutes)) was saved"))
                            .font(.headline)
                        Text(CaptionLayout.directed(recent.title ?? recent.preview))
                            .font(.subheadline)
                            .lineLimit(2)
                            .opacity(0.8)
                        Text(tr("הקישו כדי לקרוא אותה", "Tap to read it"))
                            .font(.subheadline.weight(.semibold))
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                withAnimation { viewModel.dismissRecentConversation() }
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("סגירה", "Close"))
        }
        .foregroundStyle(theme.chrome)
        .padding(14)
        .background(theme.chrome.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    /// Finished lines reach VoiceOver (speech or a braille display) by
    /// themselves. Each announcement waits for VoiceOver to finish the one
    /// before, so a line that finishes while the last is still being read
    /// doesn't cut it off mid-sentence.
    private func announceNewLines() {
        guard let text = viewModel.captionAnnouncement(voiceOverRunning: UIAccessibility.isVoiceOverRunning) else { return }
        let announcement = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }

    /// A doorbell, an alarm or her name, read out by VoiceOver as soon as
    /// it happens. The banner and the buzz can't be seen or felt by
    /// everyone who needs them, so alerts are spoken whatever the setting
    /// for reading caption lines says.
    private func announceAlert(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// Captions that stopped by themselves, and their return, spoken the
    /// same way (see `CaptionsStopAnnouncer`).
    private func announceStopOrReturn(_ phase: PipelinePhase) {
        switch stopAnnouncer.phaseChanged(to: phase) {
        case .stopped?:
            announceAlert(tr("הכתוביות נעצרו: \(presentation.title)", "Captions stopped: \(presentation.title)"))
        case .back?:
            announceAlert(tr("הכתוביות חזרו", "Captions are back"))
        case nil:
            break
        }
    }

    /// "a minute ago", "two minutes ago" (Hebrew's own dual form), "7 minutes ago".
    static func minutesAgoText(_ minutes: Int) -> String {
        HebrewTime.minutesAgo(minutes)
    }

    private var jumpToLatestPill: some View {
        Button {
            isPinnedToBottom = true
            scrollToLatest(animated: true)
        } label: {
            Label(jumpToLatestTitle, systemImage: "arrow.down.to.line")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                // A target a shaky finger finds at any text size.
                .frame(minHeight: 48)
                .ozenGlass(in: Capsule(), interactive: true, fallback: .thinMaterial)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.chrome)
        .accessibilityHint(tr("מעבר לשורה האחרונה", "Jump to the last line"))
    }

    private var jumpToLatestTitle: String {
        let newLines = viewModel.segments.count - lineCountWhenUnpinned
        guard newLines > 0 else { return tr("לשורה האחרונה", "To the last line") }
        return ConversationStats.linesText(newLines, adjective: (singular: "חדשה", plural: "חדשות"), englishAdjective: "new")
    }

    private var hidingControlBar: some View {
        controlBar
            .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height } action: { height in controlBarHeight = height }
            .offset(y: controlsHidden ? controlBarHeight + 40 : 0)
            .opacity(controlsHidden ? 0 : 1)
            .allowsHitTesting(!controlsHidden)
            .accessibilityHidden(controlsHidden)
    }

    private var showControlsButton: some View {
        Button {
            revealControls()
        } label: {
            Image(systemName: "chevron.up")
                .font(.title3.weight(.semibold))
                // The one control left once the bar hides: at least the
                // 44-point target a shaky finger needs.
                .frame(width: 64, height: 44)
                .ozenGlass(in: Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.chrome)
        .padding(.bottom, 8)
        .accessibilityLabel(tr("הצגת הכפתורים", "Show the buttons"))
        .accessibilityIdentifier("showControlsButton")
    }

    private func revealControls() {
        lastTouchAt = Date().timeIntervalSince1970
        updateControlsVisibility()
    }

    private func updateControlsVisibility() {
        let hide = ControlBarAutoHide.hides(
            enabled: viewModel.display.autoHideControls,
            isListening: viewModel.isListening,
            followingLatest: isPinnedToBottom,
            hasLines: !viewModel.segments.isEmpty,
            voiceOverRunning: UIAccessibility.isVoiceOverRunning,
            lastTouchAt: lastTouchAt,
            now: Date().timeIntervalSince1970
        )
        guard hide != controlsHidden else { return }
        if reduceMotion {
            controlsHidden = hide
        } else {
            withAnimation(.easeInOut(duration: 0.3)) { controlsHidden = hide }
        }
        scrollToLatestIfPinned()
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
        vibrate(.speechResumed)
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(alignment: .center, spacing: 8) {
            micButton
            statusControl
                .frame(maxWidth: .infinity)
            typeToSpeakButton
            if !viewModel.segments.isEmpty {
                clearButton
            }
            settingsButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: horizontalSizeClass == .regular ? 720 : .infinity)
        .ozenGlassBar()
        .foregroundStyle(theme.chrome)
    }

    private var micButton: some View {
        Button {
            showingMicPicker = true
        } label: {
            VStack(spacing: 4) {
                Image(systemName: MicPickerView.icon(for: viewModel.selectedInput?.portType ?? .other))
                    .font(.title2)
                Text(viewModel.selectedInput.map(MicPickerView.shortName) ?? tr("מיקרופון", "Microphone"))
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(width: 56)
        }
        .ozenGlassButton()
        .accessibilityLabel(tr("בחירת מיקרופון", "Choose microphone"))
        .accessibilityValue(viewModel.selectedInput?.portName ?? "")
        .accessibilityIdentifier("micPickerButton")
    }

    private var typeToSpeakButton: some View {
        Button {
            showingTypeToSpeak = true
        } label: {
            VStack(spacing: 4) {
                Image(systemName: viewModel.isSpeaking ? "speaker.wave.3.fill" : "keyboard")
                    .font(.title2)
                Text(tr("להגיד", "Say"))
                    .font(.caption2)
            }
            .frame(width: 56)
        }
        .ozenGlassButton()
        .accessibilityLabel(tr("להגיד משהו בקול", "Say something out loud"))
        .accessibilityIdentifier("typeToSpeakButton")
    }

    /// Wipes the captions off the screen and starts fresh. What was said is
    /// kept in History first when saving is on, so nothing is lost with a tap;
    /// with saving off, or saving failing, it asks before throwing the lines
    /// away. Shown only when there is something to clear.
    private var clearButton: some View {
        Button {
            if clearKeepsHistory {
                viewModel.clearTranscript()
            } else {
                confirmingClear = true
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "trash")
                    .font(.title2)
                Text(tr("ניקוי", "Clear"))
                    .font(.caption2)
            }
            .frame(width: 56)
        }
        .ozenGlassButton()
        .accessibilityLabel(tr("ניקוי הכתוביות מהמסך", "Clear the captions from the screen"))
        .accessibilityIdentifier("clearButton")
    }

    private var settingsButton: some View {
        Button {
            showingSettings = true
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "gearshape")
                    .font(.title2)
                Text(tr("הגדרות", "Settings"))
                    .font(.caption2)
            }
            .frame(width: 56)
        }
        .ozenGlassButton()
        .accessibilityLabel(tr("הגדרות", "Settings"))
        .accessibilityIdentifier("settingsButton")
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
                            .tint(current.tint.readable(on: theme.colorScheme))
                    } else {
                        Image(systemName: current.systemImage)
                    }
                    Text(current.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .multilineTextAlignment(.center)
                }
                // "Loading the model" in plain yellow is close to invisible
                // on the white theme.
                .foregroundStyle(current.tint.readable(on: theme.colorScheme))

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
                        .tint(current.tint.readable(on: theme.colorScheme))
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

    /// A screen with its own `alertOverlay` is over the captions. The
    /// caption screen then leaves the banner, pill and flash to it: behind a
    /// half-height sheet both would show, twice, for one doorbell. The
    /// vibration and the VoiceOver announcement still come from here, once.
    private var isCoveredByAlertScreen: Bool {
        showingMicPicker || showingSettings || showingTypeToSpeak || showingBigText || showingNameAlertForm
    }

    /// Vibrates for an alert while the sound classifier looks away, so the
    /// buzz on the table isn't taken for a phone ringing.
    private func vibrate(_ vibration: AlertVibration) {
        viewModel.pipeline.ignoreSounds(whileVibrating: vibration)
        AlertHapticPlayer.shared.play(vibration)
    }

    /// Opens the big-letters pad a Shortcut asked for. Only one sheet can
    /// be up at a time: with Settings or the typing sheet already open, the
    /// pad would silently fail to appear, so whatever is open closes first.
    private func presentBigText() {
        viewModel.isShowingBigText = false
        // Opened from Siri or the Action button, the pad is for someone new;
        // what the last person wrote on it is not theirs to read.
        bigText = ""
        let somethingOpen = showingMicPicker || showingSettings || showingTypeToSpeak
            || namingSegment != nil || fixingWordFromSegment != nil || openedConversation != nil
        showingMicPicker = false
        showingSettings = false
        showingTypeToSpeak = false
        namingSegment = nil
        fixingWordFromSegment = nil
        openedConversation = nil
        Task {
            // Give the closing sheet its animation before the next one.
            if somethingOpen { try? await Task.sleep(for: .milliseconds(700)) }
            showingBigText = true
        }
    }

    private var cellularDownloadMessage: String {
        let megabytes = viewModel.phase.failure?.engineUnavailability?.downloadMegabytes ?? 0
        let size = megabytes > 0 ? "\(megabytes) MB" : tr("כמה מאות MB", "A few hundred MB")
        return tr("המודל שוקל \(size). בחבילת גלישה זה יכול לעלות כסף או לגמור את נפח הגלישה. ב-Wi-Fi ההורדה תתחיל לבד.", "The model is about \(size). Over cellular data this can cost money or use up your data plan. On Wi‑Fi the download will start on its own.")
    }

    private func perform(_ action: PhasePresentation.Action) {
        switch action {
        case .none:
            break
        case .start, .pause, .resume:
            // A ghost interruption (iOS never said the call ended) shows
            // this same action; the tap tries to take the microphone back
            // instead of the ordinary pause/resume toggle.
            if viewModel.isInterruptedBySystem {
                viewModel.reclaimMicrophoneAfterCall()
            } else {
                Task { await viewModel.togglePause() }
            }
        case .stopSpeaking:
            viewModel.stopSpeaking()
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

private struct OpenedConversation: Identifiable {
    let id: UUID
    var lineID: UUID? = nil
}
