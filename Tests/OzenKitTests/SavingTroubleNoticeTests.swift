import Testing
@testable import OzenKit

@Suite("SavingTroubleNotice")
struct SavingTroubleNoticeTests {
    @Test("English title and detail")
    func englishWording() {
        Localization.$override.withValue(.english) {
            #expect(SavingTroubleNotice.title == "Saving on the phone failed")
            #expect(SavingTroubleNotice.detail.contains("iPhone Storage"))
        }
    }

    @Test("nothing to say while every save works")
    func quietWhileSaving() {
        var notice = SavingTroubleNotice()
        #expect(!notice.shouldShow)
        notice.update(settingsFailed: false, historyFailed: false)
        #expect(!notice.shouldShow)
        #expect(!notice.isFailing)
    }

    @Test("either kind of failed save shows it")
    func eitherFailureShows() {
        var settings = SavingTroubleNotice()
        settings.update(settingsFailed: true, historyFailed: false)
        #expect(settings.shouldShow)

        var history = SavingTroubleNotice()
        history.update(settingsFailed: false, historyFailed: true)
        #expect(history.shouldShow)
    }

    @Test("dismissed, it stays away while saving keeps failing")
    func dismissedStaysAway() {
        var notice = SavingTroubleNotice()
        notice.update(settingsFailed: false, historyFailed: true)
        notice.dismiss()
        #expect(!notice.shouldShow)
        notice.update(settingsFailed: true, historyFailed: true)
        #expect(!notice.shouldShow)
        #expect(notice.isFailing)
    }

    @Test("once saving works again, a new failure shows it again")
    func newFailureAfterRecoveryShows() {
        var notice = SavingTroubleNotice()
        notice.update(settingsFailed: true, historyFailed: false)
        notice.dismiss()
        notice.update(settingsFailed: false, historyFailed: false)
        #expect(!notice.shouldShow)
        notice.update(settingsFailed: false, historyFailed: true)
        #expect(notice.shouldShow)
    }
}
