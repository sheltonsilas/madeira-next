import XCTest
@testable import MadeiraNext

final class MachineImageTests: XCTestCase {
    private var directory: URL!
    private var machineID: UUID!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        machineID = UUID()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: MachineDirectory.forMachine(id: machineID))
    }

    // MARK: Names

    func testNamesThatWouldBreakACommandLineAreCleaned() {
        // A comma is the one that matters: -drive's option string cannot escape
        // one, so a file named with it cannot be named on the command line at all.
        XCTAssertEqual(MachineImage.sanitized("ubuntu,server.iso"), "ubuntu_server.iso")
        XCTAssertEqual(MachineImage.sanitized("a/b\\c.iso"), "a_b_c.iso")
        XCTAssertEqual(MachineImage.sanitized("  ubuntu.iso  "), "ubuntu.iso")
        XCTAssertEqual(MachineImage.sanitized(".."), "disk.img")
        XCTAssertEqual(MachineImage.sanitized("."), "disk.img")
        XCTAssertEqual(MachineImage.sanitized(""), "disk.img")
    }

    // MARK: Sniffing

    private func write(_ bytes: Data, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func writeISO(named name: String) throws -> URL {
        // An ISO's primary volume descriptor keeps "CD001" at 32769.
        var data = Data(repeating: 0, count: 32774)
        data.replaceSubrange(32769..<32774, with: Data("CD001".utf8))
        return try write(data, named: name)
    }

    func testAQcow2HeaderIsSniffedWhateverTheFileIsCalled() throws {
        // Ubuntu and Debian publish qcow2 images under a name ending in .img, and
        // a qcow2 disk attached as raw does not boot.
        var header = Data([0x51, 0x46, 0x49, 0xFB])
        header.append(Data(repeating: 0, count: 1024))
        let file = try write(header, named: "ubuntu-24.04-server-cloudimg-arm64.img")
        XCTAssertEqual(MachineImage.sniffFormat(atPath: file.path), "qcow2")
    }

    func testAnIsoIsSniffedByItsVolumeDescriptor() throws {
        let file = try writeISO(named: "ubuntu.iso")
        XCTAssertEqual(MachineImage.sniffFormat(atPath: file.path), "iso")
    }

    func testAnythingElseIsRaw() throws {
        let file = try write(Data(repeating: 0xAB, count: 4096), named: "disk.img")
        XCTAssertEqual(MachineImage.sniffFormat(atPath: file.path), "raw")
    }

    func testAShortFileIsNotAnISOAndIsNotAnError() throws {
        let file = try write(Data([0x00, 0x01]), named: "stub.iso")
        XCTAssertEqual(MachineImage.sniffFormat(atPath: file.path), "raw")
    }

    func testSniffingAMissingFileAnswersNothing() {
        XCTAssertNil(MachineImage.sniffFormat(atPath: directory.appendingPathComponent("nope").path))
    }

    func testARecordedFormatWinsOverTheBytes() throws {
        // What the catalogue recorded is what the download really is; the bytes
        // are only a fallback for a file nobody wrote down.
        let file = try write(Data(repeating: 0, count: 1024), named: "mystery.iso")
        XCTAssertEqual(MachineImage.format(atPath: file.path, recorded: "qcow2"), "qcow2")
        XCTAssertEqual(MachineImage.format(atPath: file.path, recorded: "  "), "raw")
    }

    func testTheFormatFallsBackToTheBytesWhenNothingIsRecorded() throws {
        let iso = try writeISO(named: "ubuntu.iso")
        XCTAssertEqual(MachineImage.format(atPath: iso.path, recorded: nil), "iso")
    }

    // MARK: Install disks

    func testAnInstallDiskIsCreatedAtTheRequestedSize() throws {
        let path = try MachineImage.createInstallDisk(for: machineID, gigabytes: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let size = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value)
        XCTAssertEqual(size, 1024 * 1024 * 1024)
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "install.raw")
    }

    func testMakingAnInstallDiskTwiceLeavesOneDiskOfTheRightSize() throws {
        let first = try MachineImage.createInstallDisk(for: machineID, gigabytes: 1)
        let second = try MachineImage.createInstallDisk(for: machineID, gigabytes: 2)
        XCTAssertEqual(first, second)
        let size = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: second)[.size] as? NSNumber)?.int64Value)
        XCTAssertEqual(size, 2 * 1024 * 1024 * 1024)
    }

    // MARK: Downloads

    func testADownloadedFileIsFoundInTheMachineFolder() throws {
        // The path a finished background download takes when no view is left to
        // receive it: the file is in the folder, and this is what notices.
        let image = try XCTUnwrap(GuestImageCatalog.images.first)
        let folder = directory.appendingPathComponent("machine", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 16).write(to: folder.appendingPathComponent(image.storedFileName))

        let found = try XCTUnwrap(MachineImage.catalogImage(in: folder))
        XCTAssertEqual(found.format, image.format.rawValue)
        XCTAssertEqual(URL(fileURLWithPath: found.path).lastPathComponent, image.storedFileName)
    }

    func testAnEmptyFolderHasNoAdoptableImage() throws {
        let folder = directory.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertNil(MachineImage.catalogImage(in: folder))
    }

    func testAFileTheCatalogueDoesNotKnowIsNotAdopted() throws {
        let folder = directory.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0x00]).write(to: folder.appendingPathComponent("my-own.iso"))
        XCTAssertNil(MachineImage.catalogImage(in: folder))
    }

    func testAdoptingMovesRatherThanCopies() throws {
        // A three-gigabyte ISO copied inside the same container needs its size in
        // free space a second time.
        let source = try write(Data(repeating: 0x7F, count: 4096), named: "ubuntu-download.iso")
        let path = try MachineImage.adoptDownloaded(source, for: machineID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "the download was copied, not moved")
        XCTAssertEqual(URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent,
                       machineID.uuidString)
    }

    func testAdoptingCleansTheNameItIsGiven() throws {
        let source = try write(Data(repeating: 0x01, count: 8), named: "odd,name.iso")
        let path = try MachineImage.adoptDownloaded(source, for: machineID)
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "odd_name.iso")
    }

    func testAMachinesFolderIsKeptOutOfICloudBackups() throws {
        // A guest is gigabytes the user can download again; it should not be what
        // fills a backup quota.
        let folder = try MachineDirectory.forMachine(id: machineID)
        let values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}
