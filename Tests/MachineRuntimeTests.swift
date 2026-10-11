import XCTest
@testable import MadeiraNext

final class MachineRuntimeTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("machine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A short template and a larger bank: the file must be extended, which is
    /// what stops QEMU refusing the machine with "device requires N bytes".
    func testVarsAreExtendedToTheFlashBankSize() throws {
        let template = folder.appendingPathComponent("template.fd")
        try Data(repeating: 0xAB, count: 4096).write(to: template)
        let firmware = LinuxFirmware(code: template, vars: template)

        let url = try XCTUnwrap(WritableFirmwareVars.url(for: firmware, flashSize: 65536, in: folder))
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
        XCTAssertEqual(size.intValue, 65536)

        // The template's own bytes survive at the front, so its variables remain.
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data[0], 0xAB)
        XCTAssertEqual(data[8191], 0xAB)
        XCTAssertEqual(data[50000], 0x00)
    }

    /// Called twice, the existing file is kept rather than rewritten.
    func testAnExistingLargeEnoughFileIsReused() throws {
        let template = folder.appendingPathComponent("template.fd")
        try Data(repeating: 0xAB, count: 4096).write(to: template)
        let firmware = LinuxFirmware(code: template, vars: template)

        let first = try XCTUnwrap(WritableFirmwareVars.url(for: firmware, flashSize: 65536, in: folder))
        let marker = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: first.path)

        let second = try XCTUnwrap(WritableFirmwareVars.url(for: firmware, flashSize: 65536, in: folder))
        XCTAssertEqual(first, second)
        let modified = try FileManager.default.attributesOfItem(atPath: second.path)[.modificationDate] as? Date
        XCTAssertEqual(modified, marker)
    }

    /// A firmware with no vars image yields nil rather than a broken file.
    func testNoVarsImageMeansNoWritableFile() {
        let code = folder.appendingPathComponent("code.fd")
        try? Data(repeating: 0, count: 4096).write(to: code)
        XCTAssertNil(WritableFirmwareVars.url(for: LinuxFirmware(code: code, vars: nil),
                                              flashSize: 65536, in: folder))
    }

    /// Without a disk image the machine is refused with a sentence, not started.
    @MainActor
    func testStartingWithoutAnImageIsRefused() {
        let machine = Machine(name: "empty", memoryMB: 2048, cpuCount: 2, imagePath: nil)
        XCTAssertThrowsError(try MachineRuntime.shared.start(machine))
        if case .failed(let why) = MachineRuntime.shared.state {
            XCTAssertFalse(why.isEmpty)
        } else {
            XCTFail("expected a failed state")
        }
    }

    func testMachineWithoutImagePathStillDecodes() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","name":"m","memoryMB":2048,"cpuCount":2}]"#
        let machines = try JSONDecoder().decode([Machine].self, from: Data(json.utf8))
        XCTAssertEqual(machines.first?.name, "m")
        XCTAssertNil(machines.first?.imagePath)
    }
}