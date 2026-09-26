import Foundation
import Testing
@testable import OzenKit

@Suite("DownloadBackgroundedNotice")
struct DownloadBackgroundedNoticeTests {
    @Test("only the downloading stage counts, not checking, loading or warming up")
    func isDownloading() {
        #expect(DownloadBackgroundedNotice.isDownloading(.preparingEngine(EnginePreparationProgress(stage: .downloadingModel))))
        #expect(!DownloadBackgroundedNotice.isDownloading(.preparingEngine(EnginePreparationProgress(stage: .checkingSupport))))
        #expect(!DownloadBackgroundedNotice.isDownloading(.preparingEngine(EnginePreparationProgress(stage: .loadingModel))))
        #expect(!DownloadBackgroundedNotice.isDownloading(.listening))
        #expect(!DownloadBackgroundedNotice.isDownloading(.idle))
    }

    @Test("posted once while the phone is put away mid-download, never while the app is on screen or switched off")
    func postsOnce() {
        var notice = DownloadBackgroundedNotice()
        #expect(notice.update(isDownloading: true, appIsActive: true, isEnabled: true) == nil)
        #expect(notice.update(isDownloading: true, appIsActive: false, isEnabled: false) == nil)

        guard case .post(let content) = notice.update(isDownloading: true, appIsActive: false, isEnabled: true) else {
            Issue.record("expected a notification")
            return
        }
        #expect(content.identifier == DownloadBackgroundedNotice.identifier)
        #expect(content.title == "ההורדה נעצרה")
        #expect(notice.update(isDownloading: true, appIsActive: false, isEnabled: true) == nil)
    }

    @Test("once the download ends the notice is withdrawn, and a later one is told again")
    func withdrawsAndRearms() {
        var notice = DownloadBackgroundedNotice()
        #expect(notice.update(isDownloading: false, appIsActive: false, isEnabled: true) == nil)
        _ = notice.update(isDownloading: true, appIsActive: false, isEnabled: true)

        #expect(notice.update(isDownloading: false, appIsActive: false, isEnabled: true) == .withdraw(identifier: DownloadBackgroundedNotice.identifier))
        #expect(notice.update(isDownloading: false, appIsActive: false, isEnabled: true) == nil)

        if case .post = notice.update(isDownloading: true, appIsActive: false, isEnabled: true) {} else {
            Issue.record("a new download after the last one ended should notify again")
        }
    }

    @Test("opening the app mid-download takes the notice away, without posting it again for the same download")
    func withdrawnOnScreen() {
        var notice = DownloadBackgroundedNotice()
        _ = notice.update(isDownloading: true, appIsActive: false, isEnabled: true)
        #expect(notice.update(isDownloading: true, appIsActive: true, isEnabled: true) == .withdraw(identifier: DownloadBackgroundedNotice.identifier))
        #expect(notice.update(isDownloading: true, appIsActive: true, isEnabled: true) == nil)
        #expect(notice.update(isDownloading: true, appIsActive: false, isEnabled: true) == nil)
    }

    @Test("the message is in English when the app is")
    func englishWording() {
        Localization.$override.withValue(.english) {
            let content = DownloadBackgroundedNotice.content
            #expect(content.title == "The download paused")
            #expect(content.body.contains("stay open"))
        }
    }
}
