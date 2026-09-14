import Foundation
import Testing
@testable import OzenKit

@Suite("Storage space gate")
struct StorageSpaceGateTests {
    private let megabyte: Int64 = 1_048_576

    @Test("enough room, counting the space the first load needs, means no shortfall")
    func enoughRoom() {
        let required = StorageSpaceGate.requiredMegabytes(forDownloadOf: 626)
        #expect(required > 626)
        #expect(StorageSpaceGate.shortfallMegabytes(downloadMegabytes: 626, availableBytes: Int64(required) * megabyte) == nil)
        #expect(StorageSpaceGate.shortfallMegabytes(downloadMegabytes: 626, availableBytes: 50_000 * megabyte) == nil)
    }

    @Test("too little room says how much more to free, rounded up")
    func shortfall() {
        let required = Int64(StorageSpaceGate.requiredMegabytes(forDownloadOf: 626))
        #expect(StorageSpaceGate.shortfallMegabytes(downloadMegabytes: 626, availableBytes: (required - 100) * megabyte) == 100)
        #expect(StorageSpaceGate.shortfallMegabytes(downloadMegabytes: 626, availableBytes: (required - 100) * megabyte + 1) == 100)
        #expect(StorageSpaceGate.shortfallMegabytes(downloadMegabytes: 626, availableBytes: required * megabyte - 1) == 1)
        #expect(StorageSpaceGate.shortfallMegabytes(downloadMegabytes: 626, availableBytes: 0) == Int(required))
    }

    @Test("a download that already fits on the phone still needs room left over")
    func headroom() {
        // 700 MB free is more than the 626 MB download, but not enough to
        // load it afterwards.
        #expect(StorageSpaceGate.shortfallMegabytes(downloadMegabytes: 626, availableBytes: 700 * megabyte) != nil)
        #expect(StorageSpaceGate.requiredMegabytes(forDownloadOf: 3_000) >= 3_000 + 750)
    }

    @Test("unknown size, unknown free space, or nothing to download: don't block")
    func unknowns() {
        #expect(StorageSpaceGate.shortfallMegabytes(downloadMegabytes: 0, availableBytes: 0) == nil)
        #expect(StorageSpaceGate.shortfallMegabytes(downloadMegabytes: 626, availableBytes: nil) == nil)
    }

    @Test("disk-full errors are recognised, even wrapped inside a download error")
    func outOfSpaceErrors() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: 640)
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let wrapped = NSError(domain: NSURLErrorDomain, code: -3003, userInfo: [NSUnderlyingErrorKey: posix])
        #expect(StorageSpaceGate.isOutOfSpace(cocoa))
        #expect(StorageSpaceGate.isOutOfSpace(posix))
        #expect(StorageSpaceGate.isOutOfSpace(wrapped))
    }

    @Test("other failures are not mistaken for a full disk")
    func otherErrors() {
        let offline = NSError(domain: NSURLErrorDomain, code: -1009)
        let permission = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let wrappedOther = NSError(domain: NSURLErrorDomain, code: -3003, userInfo: [NSUnderlyingErrorKey: permission])
        #expect(!StorageSpaceGate.isOutOfSpace(offline))
        #expect(!StorageSpaceGate.isOutOfSpace(permission))
        #expect(!StorageSpaceGate.isOutOfSpace(wrappedOther))
    }

    @Test("automatic recovery never retries a full phone on a timer")
    func neverOnATimer() {
        let failure = PipelineFailure(kind: .engineUnavailable, detail: "", engineUnavailability: EngineUnavailability(kind: .notEnoughStorage, detail: ""))
        #expect(AutoRecoveryPolicy.schedule(for: failure) == .never)
    }
}
