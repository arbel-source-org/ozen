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
        #expect(WhisperModelCatalog.variant(fromFolderName: "openai_whisper-large-v3-v20240930_626MB") == "large-v3-v20240930_626MB")
        #expect(WhisperModelCatalog.variant(fromFolderName: "distil-whisper_distil-large-v3") == nil)
    }

    @Test("size labels switch to GB at a thousand megabytes")
    func sizeLabels() {
        #expect(WhisperModelCatalog.option(for: "small")?.sizeLabel == "486 MB")
        #expect(WhisperModelCatalog.option(for: "large-v3")?.sizeLabel == "3.1 GB")
    }
}
