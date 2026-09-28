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
