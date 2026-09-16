import SwiftUI
import OzenKit
import OzenPlatform

/// Pick, download, and delete Whisper models. Selecting one restarts the
/// pipeline; the download's progress shows both here and in the main
/// screen's status control, so leaving this screen doesn't hide it.
struct ModelManagerView: View {
    @Bindable var viewModel: LiveCaptionViewModel
    @State private var installed: Set<String> = []
    /// Downloads that were cut off: files on disk, not yet a model.
    @State private var partial: Set<String> = []
    @State private var sizesOnDisk: [String: Int64] = [:]
    @State private var totalOnDisk: Int64 = 0
    /// Room left on the phone, so a model that won't fit says so before
    /// it's picked.
    @State private var freeBytes: Int64?
    @State private var pendingDelete: WhisperModelOption?
    /// A model still to download, picked while captions run: they stop
    /// until it has arrived, which can be minutes, so that is asked first.
    @State private var pendingSwitch: WhisperModelOption?
    @State private var deleteError: String?

    private let store = WhisperModelStore()

    var body: some View {
        List {
            Section {
                ForEach(WhisperModelCatalog.options) { option in
                    row(for: option)
                }
            } header: {
                Text(tr("מודלים", "Models"))
            } footer: {
                Text(tr("הורדה נעשית פעם אחת ונשמרת בטלפון (לא מגובה ל‑iCloud). סה\"כ שטח: \(Self.format(bytes: totalOnDisk)).", "Downloaded once and saved on the phone (not backed up to iCloud). Total space: \(Self.format(bytes: totalOnDisk)).") + (freeBytes.map { " " + tr("פנוי בטלפון: \(Self.format(bytes: $0)).", "Free on the phone: \(Self.format(bytes: $0)).") } ?? ""))
            }
        }
        .accessibilityIdentifier("modelManagerScreen")
        .navigationTitle(tr("מודל Whisper", "Whisper model"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .onChange(of: viewModel.phase.step) { _, _ in refresh() }
        .confirmationDialog(
            tr("למחוק את \(pendingDelete?.displayName ?? "") מהטלפון?", "Delete \(pendingDelete?.displayName ?? "") from the phone?"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(tr("מחיקה", "Delete"), role: .destructive) {
                if let option = pendingDelete { delete(option) }
            }
            Button(tr("ביטול", "Cancel"), role: .cancel) {}
        } message: {
            if let option = pendingDelete, option.variant == viewModel.settings.whisperModelVariant {
                // The picked one: the next time it has to load (the next
                // launch, say) it downloads all over again first, which
                // with no Wi-Fi nearby is a long wait nobody expects.
                Text(tr("זה המודל שנבחר. בפעם הבאה שהוא ייטען, למשל כשהאפליקציה תיפתח מחדש, הוא יירד שוב (\(option.sizeLabel)) לפני שיהיו כתוביות.", "This is the selected model. Next time it needs to load, for example when the app reopens, it will download again (\(option.sizeLabel)) before there are captions."))
            } else {
                Text(tr("אפשר להוריד אותו שוב בכל עת.", "It can be downloaded again anytime."))
            }
        }
        .confirmationDialog(
            tr("להוריד את \(pendingSwitch?.displayName ?? "") ולעבור אליו?", "Download \(pendingSwitch?.displayName ?? "") and switch to it?"),
            isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }),
            titleVisibility: .visible,
            presenting: pendingSwitch
        ) { option in
            Button(tr("להוריד ולעבור", "Download and switch")) {
                Task { await viewModel.setWhisperModel(option.variant) }
            }
            Button(tr("ביטול", "Cancel"), role: .cancel) {}
        } message: { option in
            Text(tr("הכתוביות ייעצרו עד שההורדה (\(option.sizeLabel)) תסתיים והמודל ייטען. בלי Wi-Fi ההורדה עשויה לחכות לו.", "Captions will stop until the download (\(option.sizeLabel)) finishes and the model loads. Without Wi‑Fi, the download may wait for it."))
        }
        .alert(tr("המחיקה נכשלה", "Delete failed"), isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button(tr("סגור", "Close"), role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func row(for option: WhisperModelOption) -> some View {
        let isSelected = option.variant == viewModel.settings.whisperModelVariant
        let isInstalled = installed.contains(option.variant)
        let isPartial = partial.contains(option.variant)
        let downloadProgress = downloadProgress(for: option)
        // Picking it would stop captions that work for a download with no
        // room to land; the row says why instead.
        let wontFit = !isInstalled && !isPartial && !isSelected
            && StorageSpaceGate.shortfallMegabytes(downloadMegabytes: option.installMegabytes, availableBytes: freeBytes) != nil

        return Button {
            if !isInstalled, !isSelected, viewModel.isListening {
                pendingSwitch = option
            } else {
                Task { await viewModel.setWhisperModel(option.variant) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(option.displayName)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                    if option.isRecommended {
                        Text(tr("מומלץ לעברית", "Recommended for Hebrew"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                HStack(spacing: 16) {
                    RatingDots(label: tr("עברית", "Hebrew"), value: option.hebrewQuality)
                    RatingDots(label: tr("מהירות", "Speed"), value: option.speed)
                }

                Text(localizedNote(for: option))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text(option.sizeLabel)
                    if let progress = downloadProgress {
                        Text(tr("· מוריד \(Int((progress * 100).rounded()))%", "· downloading \(Int((progress * 100).rounded()))%"))
                    } else if isInstalled {
                        Image(systemName: "checkmark")
                        Text(tr("מותקן", "Installed"))
                        if let size = sizesOnDisk[option.variant] {
                            Text(tr("· \(Self.format(bytes: size)) בפועל", "· \(Self.format(bytes: size)) actual"))
                        }
                    } else if isPartial {
                        Image(systemName: "exclamationmark.arrow.circlepath")
                        Text(tr("ההורדה נקטעה · תימשך מאיפה שנעצרה בבחירה", "Download interrupted · will resume from where it stopped when selected"))
                        if let size = sizesOnDisk[option.variant] {
                            Text(tr("· \(Self.format(bytes: size)) כבר ירדו", "· \(Self.format(bytes: size)) already downloaded"))
                        }
                    } else if StorageSpaceGate.shortfallMegabytes(downloadMegabytes: option.installMegabytes, availableBytes: freeBytes) != nil {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                        Text(tr("אין מספיק מקום בטלפון", "Not enough room on the phone"))
                    } else {
                        Image(systemName: "icloud.and.arrow.down")
                        Text(tr("יורד בבחירה", "Downloads when selected"))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let progress = downloadProgress {
                    ProgressView(value: progress)
                    if let seconds = viewModel.pipeline.downloadSecondsRemaining {
                        Text(PhasePresentation.remainingText(seconds: seconds))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .disabled(wontFit)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if (isInstalled || isPartial) && !(isSelected && (viewModel.isListening || viewModel.phase.isTransitioning)) {
                Button(role: .destructive) {
                    pendingDelete = option
                } label: {
                    Label(tr("מחיקה", "Delete"), systemImage: "trash")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func downloadProgress(for option: WhisperModelOption) -> Double? {
        guard let progress = viewModel.phase.preparationProgress,
              progress.stage == .downloadingModel,
              progress.detail == option.variant
        else { return nil }
        return progress.fraction ?? 0
    }

    private func localizedNote(for option: WhisperModelOption) -> String {
        switch option.variant {
        case "tiny": return tr("הכי מהיר. העברית שלו בעיקר שגויה — רק לבדיקת המיקרופון.", "The fastest. Its Hebrew is mostly wrong — for testing the microphone only.")
        case "base": return tr("מהיר מאוד, עדיין חלש בעברית.", "Very fast, still weak at Hebrew.")
        case "small_216MB": return tr("חצי מההורדה של Small עם כמעט אותן תוצאות.", "Half the download of Small with nearly the same results.")
        case "small": return tr("הורדה קצרה ותגובה מהירה. עברית מובנת, עם טעויות.", "A short download and a quick response. Hebrew is understandable, with mistakes.")
        case "ivrit-large-v3-turbo-8bit": return tr("Turbo שאומן על כ-5,000 שעות של עברית על ידי ivrit.ai: שליש פחות מילים שגויות מ-Turbo בהקלטות בדיקה. מהיר באותה מידה, הורדה גדולה יותר.", "Turbo trained on about 5,000 hours of Hebrew by ivrit.ai: a third fewer wrong words than Turbo on test recordings. As quick, a bigger download.")
        case "large-v3-v20240930_626MB": return tr("עברית טובה בהרבה מ‑Small באותו גודל הורדה בערך. קצת יותר איטי בכל עדכון.", "Much better Hebrew than Small at roughly the same download size. A bit slower on each update.")
        case "large-v3-v20240930": return tr("Turbo בדיוק מלא. אותה רמת דיוק, הורדה גדולה יותר.", "Turbo at full precision. Same accuracy, a larger download.")
        case "medium": return tr("מודל ביניים ישן יותר; Turbo גם מדויק יותר וגם מהיר יותר.", "An older mid-size model; Turbo is both more accurate and faster.")
        case "large-v3_947MB": return tr("הדיוק הגבוה ביותר, אבל איטי מדי כדי להרגיש \"חי\" בטלפון.", "The highest accuracy, but too slow to feel “live” on the phone.")
        case "large-v3": return tr("3 GB. הכי מדויק, הכי איטי; להשוואה בלבד.", "3 GB. The most accurate, the slowest; for comparison only.")
        default: return option.note
        }
    }

    private func refresh() {
        installed = Set(store.installedVariants())
        // Skip the variant being downloaded right now: mid-download is
        // expected to be incomplete and already shows its progress.
        let downloading = viewModel.phase.preparationProgress.flatMap { $0.stage == .downloadingModel ? $0.detail : nil }
        partial = Set(WhisperModelCatalog.options.map(\.variant).filter { variant in
            variant != downloading && store.state(of: variant) == .partial
        })
        sizesOnDisk = Dictionary(uniqueKeysWithValues: installed.union(partial).map { ($0, store.sizeOnDisk(of: $0)) })
        totalOnDisk = store.totalSizeOnDisk()
        freeBytes = DeviceStorage.availableBytes()
    }

    private func delete(_ option: WhisperModelOption) {
        do {
            try store.delete(variant: option.variant)
        } catch {
            deleteError = error.localizedDescription
        }
        refresh()
    }

    static func format(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct RatingDots: View {
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { index in
                    Circle()
                        .fill(index <= value ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 7, height: 7)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("\(label) \(value) מתוך 5", "\(label) \(value) out of 5"))
    }
}
