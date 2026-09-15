import Foundation

/// One Whisper model the app offers. Sizes were measured from the actual
/// `argmaxinc/whisperkit-coreml` repository listing on 2026-09-13; Hebrew
/// quality and speed are 1–5 ratings from Whisper's published per-language
/// error rates and WhisperKit's iPhone benchmarks — a guide for choosing,
/// not a promise. The variant string is what `WhisperKit.download` matches
/// against folder names (`openai_whisper-<variant>`).
public struct WhisperModelOption: Sendable, Equatable, Identifiable {
    public let variant: String
    public let displayName: String
    public let sizeMB: Int
    /// 1 (barely usable for Hebrew) … 5 (best Whisper can do).
    public let hebrewQuality: Int
    /// 1 (too slow for live use on a phone) … 5 (instant).
    public let speed: Int
    public let note: String
    public let isRecommended: Bool
    /// Where the files come from; see `WhisperModelSource`.
    public let source: WhisperModelSource
    /// The model's folder name on disk. WhisperKit's hub names folders
    /// `openai_whisper-<variant>`; a model from elsewhere says its own.
    public let folderName: String

    public init(
        variant: String,
        displayName: String,
        sizeMB: Int,
        hebrewQuality: Int,
        speed: Int,
        note: String,
        isRecommended: Bool,
        source: WhisperModelSource = .whisperKitHub,
        folderName: String? = nil
    ) {
        self.variant = variant
        self.displayName = displayName
        self.sizeMB = sizeMB
        self.hebrewQuality = hebrewQuality
        self.speed = speed
        self.note = note
        self.isRecommended = isRecommended
        self.source = source
        self.folderName = folderName ?? "openai_whisper-\(variant)"
    }

    public var id: String { variant }

    /// Not an exact byte count — a human-scale label for the picker.
    public var sizeLabel: String {
        sizeMB >= 1000
            ? String(format: "%.1f GB", Double(sizeMB) / 1000)
            : "\(sizeMB) MB"
    }
}

/// The curated subset of WhisperKit's model zoo that makes sense for a
/// live Hebrew captioner on a modern iPhone. English-only variants
/// (`.en`, distil) are deliberately absent; the 3 GB full-precision
/// large models are listed but marked slow, so the choice is honest.
public enum WhisperModelCatalog {
    public static let options: [WhisperModelOption] = [
        WhisperModelOption(
            variant: "tiny", displayName: "Tiny", sizeMB: 76,
            hebrewQuality: 1, speed: 5,
            note: "Fastest. Hebrew is mostly wrong — only for testing the microphone.",
            isRecommended: false
        ),
        WhisperModelOption(
            variant: "base", displayName: "Base", sizeMB: 146,
            hebrewQuality: 1, speed: 5,
            note: "Very fast, still weak in Hebrew.",
            isRecommended: false
        ),
        WhisperModelOption(
            variant: "small_216MB", displayName: "Small (compressed)", sizeMB: 217,
            hebrewQuality: 2, speed: 4,
            note: "Half the download of Small with nearly the same results.",
            isRecommended: false
        ),
        WhisperModelOption(
            variant: "small", displayName: "Small", sizeMB: 486,
            hebrewQuality: 2, speed: 4,
            note: "Quick to download and responsive. Understandable Hebrew, with mistakes.",
            isRecommended: false
        ),
        WhisperModelOption(
            variant: "large-v3-v20240930_626MB", displayName: "Turbo (compressed)", sizeMB: 626,
            hebrewQuality: 4, speed: 3,
            note: "Much better Hebrew than Small for about the same download. Slightly slower per update.",
            isRecommended: true
        ),
        WhisperModelOption(
            variant: "large-v3-v20240930", displayName: "Turbo", sizeMB: 1619,
            hebrewQuality: 4, speed: 3,
            note: "Full-precision Turbo. Same accuracy class as the compressed one, bigger download.",
            isRecommended: false
        ),
        WhisperModelOption(
            variant: "medium", displayName: "Medium", sizeMB: 1529,
            hebrewQuality: 3, speed: 2,
            note: "Older mid-size model; Turbo is both better and faster.",
            isRecommended: false
        ),
        WhisperModelOption(
            variant: "large-v3_947MB", displayName: "Large v3 (compressed)", sizeMB: 948,
            hebrewQuality: 5, speed: 1,
            note: "Best accuracy, but too slow to feel live on a phone.",
            isRecommended: false
        ),
        WhisperModelOption(
            variant: "large-v3", displayName: "Large v3", sizeMB: 3090,
            hebrewQuality: 5, speed: 1,
            note: "3 GB. Best accuracy, slowest; for reference only.",
            isRecommended: false
        ),
    ]

    /// What a fresh install gets. The recommended model: on Hebrew test
    /// recordings Small got 60% of words wrong against 39% for Turbo, for
    /// only a slightly bigger download, so nobody should end up on Small
    /// without choosing it.
    public static let defaultVariant = recommendedVariant
    public static let recommendedVariant = "large-v3-v20240930_626MB"

    public static func option(for variant: String) -> WhisperModelOption? {
        options.first { $0.variant == variant }
    }

    /// Whether the recommended model is clearly better in Hebrew than
    /// `variant`: the case for a phone set up when Small was the default.
    /// A variant the catalog doesn't know can't be judged, so it isn't.
    public static func recommendedImproves(on variant: String) -> Bool {
        guard let current = option(for: variant), let recommended = option(for: recommendedVariant) else { return false }
        return recommended.hebrewQuality > current.hebrewQuality
    }

    /// The on-disk folder name of a variant: the option's own, or the name
    /// WhisperKit's model repository uses for one the catalog doesn't
    /// list. Kept here (next to the variant list) so the model store and
    /// the download code can't drift apart on naming.
    public static func folderName(for variant: String) -> String {
        option(for: variant)?.folderName ?? "openai_whisper-\(variant)"
    }

    public static func variant(fromFolderName name: String) -> String? {
        if let listed = options.first(where: { $0.folderName == name }) { return listed.variant }
        let prefix = "openai_whisper-"
        guard name.hasPrefix(prefix) else { return nil }
        return String(name.dropFirst(prefix.count))
    }
}
