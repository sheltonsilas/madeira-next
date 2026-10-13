import XCTest
@testable import MadeiraNext

final class ImageCatalogTests: XCTestCase {

    func testEveryIdentifierIsUnique() {
        let imageIDs = GuestImageCatalog.images.map(\.id)
        XCTAssertEqual(Set(imageIDs).count, imageIDs.count, "two images share an id")
        let distributionIDs = GuestImageCatalog.all.map(\.id)
        XCTAssertEqual(Set(distributionIDs).count, distributionIDs.count)
        XCTAssertFalse(imageIDs.isEmpty)
    }

    func testEveryImageIsHttpsAndItsNameIsTheLastPathComponent() {
        // The name in the table is what the checksum list is searched for, so a
        // name that is not the server's file name verifies nothing.
        for image in GuestImageCatalog.images {
            XCTAssertEqual(image.url.scheme, "https", "\(image.id) is not https")
            XCTAssertEqual(image.url.lastPathComponent, image.remoteFileName,
                           "\(image.id): the name in the table is not the name in the URL")
            XCTAssertGreaterThan(image.byteCount, 0, "\(image.id) has no size, so progress cannot be shown")
        }
    }

    func testEveryStoredNameMatchesTheFormatItIsReadAs() {
        // The stored extension is what QEMU is told to read, and the launcher
        // falls back to it. An image stored as .qcow2 must therefore really be
        // qcow2, and one stored as .iso really an ISO.
        for image in GuestImageCatalog.images {
            let name = image.storedFileName.lowercased()
            switch image.format {
            case .iso:
                XCTAssertTrue(name.hasSuffix(".iso"), "\(image.id) is an ISO stored as \(image.storedFileName)")
            case .qcow2:
                XCTAssertTrue(name.hasSuffix(".qcow2"),
                              "\(image.id) is qcow2 stored as \(image.storedFileName): a cloud image published as .img must be renamed, or it is attached as raw")
            case .raw:
                XCTAssertTrue(name.hasSuffix(".img") || name.hasSuffix(".raw"))
            }
        }
    }

    func testAChecksumAlgorithmComesWithAChecksumList() {
        for image in GuestImageCatalog.images {
            XCTAssertEqual(image.checksumURL == nil, image.checksumAlgorithm == nil,
                           "\(image.id) has one of a checksum list and an algorithm without the other")
        }
    }

    func testInstallersAreTheOnesThatNeedADisk() {
        for image in GuestImageCatalog.images {
            XCTAssertEqual(image.kind == .installer, image.needsInstallDisk,
                           "\(image.id) is an installer without a disk requirement or the reverse")
        }
    }

    func testImagesHaveAHumanSizeAndAKind() {
        for image in GuestImageCatalog.images {
            XCTAssertFalse(image.sizeDescription.isEmpty)
            XCTAssertFalse(image.kind.title.isEmpty)
            XCTAssertFalse(image.kind.summary.isEmpty)
        }
    }

    func testLookupsFindWhatIsInTheTable() {
        let first = GuestImageCatalog.images[0]
        XCTAssertEqual(GuestImageCatalog.image(id: first.id), first)
        XCTAssertNil(GuestImageCatalog.image(id: "not-a-distribution"))
    }

    func testWindowsIsDocumentedRatherThanInvented() {
        // There is no downloadable Windows ARM64 ISO, so there is no catalogue
        // entry claiming one. What there is has to say where a user gets one and
        // what will refuse to install.
        XCTAssertFalse(WindowsImageGuidance.summary.isEmpty)
        XCTAssertGreaterThanOrEqual(WindowsImageGuidance.steps.count, 3)
        XCTAssertEqual(WindowsImageGuidance.sourceURL.scheme, "https")
        XCTAssertTrue(WindowsImageGuidance.steps.contains { $0.contains("TPM") },
                      "the TPM refusal is the one thing a Windows 11 install stops on")
        XCTAssertTrue(WindowsImageGuidance.steps.contains { $0.contains("USB mass storage") },
                      "the device choice is why a Windows guest can see a disk at all")
        XCTAssertFalse(GuestImageCatalog.images.contains { $0.format == .iso && $0.url.host?.contains("microsoft") == true })
    }

    // MARK: Checksum parsing

    func testHashListIsParsedInBothOfItsForms() {
        let list = """
        aaaa  ubuntu-24.04-server-cloudimg-arm64.img
        bbbb *ubuntu-24.04.3-desktop-arm64.iso
        cccc  ./sub/dir/other.iso
        """
        XCTAssertEqual(ImageDownloader.expectedHash(in: list, for: "ubuntu-24.04-server-cloudimg-arm64.img"), "aaaa")
        XCTAssertEqual(ImageDownloader.expectedHash(in: list, for: "ubuntu-24.04.3-desktop-arm64.iso"), "bbbb")
        XCTAssertEqual(ImageDownloader.expectedHash(in: list, for: "other.iso"), "cccc")
    }

    func testAFileTheListDoesNotMentionHasNoHash() {
        // A list that does not mention our file is a newer image than this build
        // knows about, not a mismatch, so it must not be reported as one.
        XCTAssertNil(ImageDownloader.expectedHash(in: "aaaa  something-else.iso", for: "ours.iso"))
        XCTAssertNil(ImageDownloader.expectedHash(in: "", for: "ours.iso"))
        XCTAssertNil(ImageDownloader.expectedHash(in: "no hash here", for: "here"))
    }

    // MARK: Hashing

    func testSha256AndSha512MatchTheKnownDigests() throws {
        // The digests of "madeira-next\n", computed with sha256sum and sha512sum.
        // If the chunked reader ever loses or repeats a byte, these are what says so.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("madeira-next\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(try ImageDownloader.hash(of: file, algorithm: .sha256),
                       "4b7bb7c79006cae3036a3ea4c75568e1891c56223e9a1652f8f326a877787b30")
        XCTAssertEqual(try ImageDownloader.hash(of: file, algorithm: .sha512),
                       "e22f3881ecd1ed6ba770037174886de838564d6e0955dc7cf27d9c1bbde3da2000c13376a8ec5a7037df7f8fe98c0866fc4c9e469302eaa8c551ae1ddcad0a89")
    }

    func testHashingAnEmptyFileMatchesTheEmptyDigest() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try ImageDownloader.hash(of: file, algorithm: .sha256),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    // MARK: Download state

    func testADownloadReportsItsOwnFractionAndNeverExceedsOne() {
        XCTAssertEqual(ImageDownloader.State.downloading(received: 5, expected: 10).fraction, 0.5)
        XCTAssertNil(ImageDownloader.State.downloading(received: 5, expected: 0).fraction)
        XCTAssertNil(ImageDownloader.State.verifying.fraction)
        XCTAssertTrue(ImageDownloader.State.verifying.isBusy)
        XCTAssertTrue(ImageDownloader.State.downloading(received: 1, expected: 2).isBusy)
        XCTAssertFalse(ImageDownloader.State.idle.isBusy)
        XCTAssertFalse(ImageDownloader.State.failed("no").isBusy)
        XCTAssertFalse(ImageDownloader.State.installed("/tmp/x").isBusy)
    }

    func testEveryBusyStateSaysSomething() {
        XCTAssertNotNil(ImageDownloader.State.verifying.detail)
        XCTAssertNotNil(ImageDownloader.State.installed("/tmp/x").detail)
        XCTAssertNotNil(ImageDownloader.State.failed("the disk was full").detail)
        XCTAssertNil(ImageDownloader.State.idle.detail)
    }
}
