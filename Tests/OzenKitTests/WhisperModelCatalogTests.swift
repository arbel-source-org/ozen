import Testing
@testable import OzenKit

@Suite("WhisperModelCatalog")
struct WhisperModelCatalogTests {
    @Test("the default and recommended variants both exist in the catalog")
    func defaultsExist() {
        #expect(WhisperModelCatalog.option(for: WhisperModelCatalog.defaultVariant) != nil)
        #expect(WhisperModelCatalog.option(for: WhisperModelCatalog.recommendedVariant)?.isRecommended == true)
        #expect(AppSettings.default.whisperModelVariant == WhisperModelCatalog.defaultVariant)
    }

    @Test("a fresh install gets the recommended model, not Small")
    func freshInstallGetsRecommended() {
        #expect(WhisperModelCatalog.defaultVariant == WhisperModelCatalog.recommendedVariant)
        #expect(AppSettings.default.whisperModelVariant == "ivrit-large-v3-turbo-8bit")
    }

    @Test("the recommended model improves on the small ones, not on its equals or betters or on strangers")
    func recommendedImproves() {
        for weaker in ["tiny", "base", "small_216MB", "small", "medium", "large-v3-v20240930_626MB", "large-v3-v20240930"] {
            #expect(WhisperModelCatalog.recommendedImproves(on: weaker), "\(weaker)")
        }
        for asGood in [WhisperModelCatalog.recommendedVariant, "large-v3_947MB", "large-v3"] {
            #expect(!WhisperModelCatalog.recommendedImproves(on: asGood), "\(asGood)")
        }
        #expect(!WhisperModelCatalog.recommendedImproves(on: "no-such-model"))
    }

    @Test("exactly one option is recommended and variants are unique")
    func oneRecommendation() {
        #expect(WhisperModelCatalog.options.filter(\.isRecommended).count == 1)
        let variants = WhisperModelCatalog.options.map(\.variant)
        #expect(Set(variants).count == variants.count)
    }

    @Test("ratings stay in the 1...5 range and no English-only model slipped in")
    func sanity() {
        for option in WhisperModelCatalog.options {
            #expect((1...5).contains(option.hebrewQuality), "\(option.variant)")
            #expect((1...5).contains(option.speed), "\(option.variant)")
            #expect(!option.variant.contains(".en"), "\(option.variant)")
            #expect(!option.variant.contains("distil"), "\(option.variant)")
            #expect(option.sizeMB > 0)
        }
    }

    @Test("folder names round-trip")
    func folderNames() {
        #expect(WhisperModelCatalog.folderName(for: "small") == "openai_whisper-small")
        #expect(WhisperModelCatalog.folderName(for: "ivrit-large-v3-turbo-8bit") == "ivrit-ai_whisper-large-v3-turbo_8bit")
        #expect(WhisperModelCatalog.variant(fromFolderName: "ivrit-ai_whisper-large-v3-turbo_8bit") == "ivrit-large-v3-turbo-8bit")
        #expect(WhisperModelCatalog.option(for: WhisperModelCatalog.recommendedVariant)?.source == .ozenRelease(tag: "model-ivrit-large-v3-turbo-8bit-1"))
        #expect(WhisperModelCatalog.variant(fromFolderName: "openai_whisper-large-v3-v20240930_626MB") == "large-v3-v20240930_626MB")
        #expect(WhisperModelCatalog.variant(fromFolderName: "distil-whisper_distil-large-v3") == nil)
    }

    @Test("size labels switch to GB at a thousand megabytes")
    func sizeLabels() {
        #expect(WhisperModelCatalog.option(for: "small")?.sizeLabel == "486 MB")
        #expect(WhisperModelCatalog.option(for: "large-v3")?.sizeLabel == "3.1 GB")
    }
}
