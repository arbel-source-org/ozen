import Testing
@testable import OzenKit

struct FirstRunNoteTests {
    @Test("only Apple's recognition warns about iOS asking for speech permission; a paired home computer says so instead")
    func notes() {
        #expect(TranscriptionEngineKind.whisperKit.firstRunNote == .modelDownload)
        #expect(TranscriptionEngineKind.appleSpeech.firstRunNote == .speechPermission)
        #expect(TranscriptionEngineKind.homeServer.firstRunNote == .homeComputer)
        #expect(TranscriptionEngineKind.cloud.firstRunNote == .none)
    }
}

struct AudioLeavesPhoneTests {
    @Test("the first page's 'nothing is sent to the internet' holds only when the audio stays on the phone")
    func leaves() {
        var settings = AppSettings.default
        settings.engine = .whisperKit
        #expect(!settings.audioLeavesPhone)
        settings.engine = .appleSpeech
        settings.allowServerFallbackForAppleSpeech = false
        #expect(!settings.audioLeavesPhone)
        settings.allowServerFallbackForAppleSpeech = true
        #expect(settings.audioLeavesPhone)
        settings.engine = .homeServer
        #expect(settings.audioLeavesPhone)
        settings.engine = .cloud
        #expect(settings.audioLeavesPhone)
    }
}
