import Foundation
import Testing
@testable import OzenKit

@Suite("Saved line read aloud")
struct SavedLineSpeechTests {
    private func line(_ text: String, speaker: String?, starred: Bool = false) -> SavedSegment {
        SavedSegment(id: UUID(), text: text, speakerName: speaker, speakerClusterID: nil, startTimestamp: 0, isCommitted: true, isStarred: starred)
    }

    @Test("the time shown above a line is read with it")
    func timeIsRead() {
        #expect(SavedLineSpeech.label(for: line("בוקר טוב", speaker: "דנה"), time: "21:04", uncertain: false) == "21:04. דנה: בוקר טוב")
        #expect(SavedLineSpeech.label(for: line("בוקר טוב", speaker: "דנה"), time: nil, uncertain: false) == "דנה: בוקר טוב")
    }

    @Test("an unrecognised voice is not read out as unknown speaker on every line, in any language it was saved in")
    func unknownSpeakerNotRead() {
        for language in UILanguage.allCases {
            let unknown = tr("דובר לא ידוע", "Unknown speaker", in: language)
            #expect(SavedLineSpeech.label(for: line("כן", speaker: unknown), time: nil, uncertain: false) == "כן")
        }
        #expect(SavedLineSpeech.label(for: line("כן", speaker: "דובר 2"), time: nil, uncertain: false) == "דובר 2: כן")
        #expect(SavedLineSpeech.label(for: line("כן", speaker: ""), time: nil, uncertain: false) == "כן")
    }

    @Test("star and doubt come before the words, after the time")
    func markers() {
        let label = SavedLineSpeech.label(for: line("כדור אחד", speaker: nil, starred: true), time: "9:30", uncertain: true)
        #expect(label == "9:30. מסומן כחשוב. ייתכן שלא נשמע נכון. כדור אחד")
    }
}
