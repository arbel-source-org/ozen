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
    @State private var deleteError: String?

    private let store = WhisperModelStore()

    var body: some View {
        List {
            Section {
                ForEach(WhisperModelCatalog.options) { option in
                    row(for: option)
                }
            } header: {
                Text("מודלים")
            } footer: {
                Text("הורדה נעשית פעם אחת ונשמרת בטלפון (לא מגובה ל‑iCloud). סה\"כ שטח: \(Self.format(bytes: totalOnDisk))." + (freeBytes.map { " פנוי בטלפון: \(Self.format(bytes: $0))." } ?? ""))
            }
        }
        .navigationTitle("מודל Whisper")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .onChange(of: viewModel.phase.step) { _, _ in refresh() }
        .confirmationDialog(
            "למחוק את \(pendingDelete?.displayName ?? "") מהטלפון?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("מחיקה", role: .destructive) {
                if let option = pendingDelete { delete(option) }
            }
            Button("ביטול", role: .cancel) {}
        } message: {
            if let option = pendingDelete, option.variant == viewModel.settings.whisperModelVariant {
                // The picked one: the next time it has to load (the next
                // launch, say) it downloads all over again first, which
                // with no Wi-Fi nearby is a long wait nobody expects.
                Text("זה המודל שנבחר. בפעם הבאה שהוא ייטען, למשל כשהאפליקציה תיפתח מחדש, הוא יירד שוב (\(option.sizeLabel)) לפני שיהיו כתוביות.")
            } else {
                Text("אפשר להוריד אותו שוב בכל עת.")
            }
        }
        .alert("המחיקה נכשלה", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("סגור", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func row(for option: WhisperModelOption) -> some View {
        let isSelected = option.variant == viewModel.settings.whisperModelVariant
        let isInstalled = installed.contains(option.variant)
        let isPartial = partial.contains(option.variant)
        let downloadProgress = downloadProgress(for: option)

        return Button {
            Task { await viewModel.setWhisperModel(option.variant) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(option.displayName)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                    if option.isRecommended {
                        Text("מומלץ לעברית")
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
                    RatingDots(label: "עברית", value: option.hebrewQuality)
                    RatingDots(label: "מהירות", value: option.speed)
                }

                Text(localizedNote(for: option))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text(option.sizeLabel)
                    if let progress = downloadProgress {
                        Text("· מוריד \(Int((progress * 100).rounded()))%")
                    } else if isInstalled {
                        Image(systemName: "checkmark")
                        Text("מותקן")
                        if let size = sizesOnDisk[option.variant] {
                            Text("· \(Self.format(bytes: size)) בפועל")
                        }
                    } else if isPartial {
                        Image(systemName: "exclamationmark.arrow.circlepath")
                        Text("ההורדה נקטעה · תימשך מאיפה שנעצרה בבחירה")
                        if let size = sizesOnDisk[option.variant] {
                            Text("· \(Self.format(bytes: size)) כבר ירדו")
                        }
                    } else if StorageSpaceGate.shortfallMegabytes(downloadMegabytes: option.sizeMB, availableBytes: freeBytes) != nil {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                        Text("אין מספיק מקום בטלפון")
                    } else {
                        Image(systemName: "icloud.and.arrow.down")
                        Text("יורד בבחירה")
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
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if (isInstalled || isPartial) && !(isSelected && (viewModel.isListening || viewModel.phase.isTransitioning)) {
                Button(role: .destructive) {
                    pendingDelete = option
                } label: {
                    Label("מחיקה", systemImage: "trash")
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
        case "tiny": return "הכי מהיר. העברית שלו בעיקר שגויה — רק לבדיקת המיקרופון."
        case "base": return "מהיר מאוד, עדיין חלש בעברית."
        case "small_216MB": return "חצי מההורדה של Small עם כמעט אותן תוצאות."
        case "small": return "ברירת המחדל: הורדה קצרה ותגובה מהירה. עברית מובנת, עם טעויות."
        case "large-v3-v20240930_626MB": return "עברית טובה בהרבה מ‑Small באותו גודל הורדה בערך. קצת יותר איטי בכל עדכון."
        case "large-v3-v20240930": return "Turbo בדיוק מלא. אותה רמת דיוק, הורדה גדולה יותר."
        case "medium": return "מודל ביניים ישן יותר; Turbo גם מדויק יותר וגם מהיר יותר."
        case "large-v3_947MB": return "הדיוק הגבוה ביותר, אבל איטי מדי כדי להרגיש \"חי\" בטלפון."
        case "large-v3": return "3 GB. הכי מדויק, הכי איטי; להשוואה בלבד."
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
        .accessibilityLabel("\(label) \(value) מתוך 5")
    }
}
