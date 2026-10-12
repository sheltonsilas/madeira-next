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

        // The template's own bytes survive at the front and the extension is
        // zeroes, so the boundary is at the template's length.
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data[0], 0xAB)
        XCTAssertEqual(data[4095], 0xAB)
        XCTAssertEqual(data[4096], 0x00)
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

    /// A socket path has to fit in `sockaddr_un.sun_path`, which is 104 bytes on
    /// Darwin. An app container is about 76 of them and a machine's folder under
    /// Library/Application Support takes a socket beside the image to over 160, so
    /// this asserts the headroom rather than a specific spelling: the simulator
    /// container is much shorter than the device's, which is why the mistake is
    /// invisible without it.
    func testSocketPathsLeaveHeadroomForTheKernelLimit() throws {
        // The device container root, as measured on iOS: the simulator's root is
        // much shorter, so the assertion is made against this length and not
        // against whatever this run happens to have.
        let deviceContainer = "/var/mobile/Containers/Data/Application/" + String(repeating: "A", count: 36)
        let sockets = try MachineDirectory.sockets()

        for id in [UUID(), UUID()] {
            for path in [try MachineDirectory.consoleSocket(id: id),
                         try MachineDirectory.monitorSocket(id: id)] {
                // Everything the path spends inside the container: /s/<name>.sock.
                let inside = String(path.dropFirst(sockets.path.count))
                let onDevice = deviceContainer.count + inside.count
                XCTAssertLessThan(onDevice, 104, "socket path must fit in sun_path: \(path)")
            }
            XCTAssertNotEqual(try MachineDirectory.consoleSocket(id: id),
                              try MachineDirectory.monitorSocket(id: id))
        }
        XCTAssertNotEqual(try MachineDirectory.consoleSocket(id: UUID()),
                          try MachineDirectory.consoleSocket(id: UUID()))
    }

    /// The two sockets must be named for the machine, which is what keeps one
    /// machine's stop from reaching another's.
    func testSocketNamesCarryTheMachineTag() throws {
        let id = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        XCTAssertTrue(try MachineDirectory.consoleSocket(id: id).hasSuffix("/cabcdef01.sock"))
        XCTAssertTrue(try MachineDirectory.monitorSocket(id: id).hasSuffix("/mabcdef01.sock"))
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

    /// A picked file name is joined onto the machine's folder, so separators and
    /// traversal are removed rather than trusted.
    func testImageNamesAreMadeSafeToJoin() {
        XCTAssertEqual(MachineImage.sanitized("ubuntu-24.04.iso"), "ubuntu-24.04.iso")
        XCTAssertEqual(MachineImage.sanitized("../../etc/passwd"), ".._.._etc_passwd")
        XCTAssertEqual(MachineImage.sanitized("a\\b.img"), "a_b.img")
        XCTAssertEqual(MachineImage.sanitized("   "), "disk.img")
        XCTAssertEqual(MachineImage.sanitized(".."), "disk.img")
    }

    func testMachineWithoutImagePathStillDecodes() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","name":"m","memoryMB":2048,"cpuCount":2}]"#
        let machines = try JSONDecoder().decode([Machine].self, from: Data(json.utf8))
        XCTAssertEqual(machines.first?.name, "m")
        XCTAssertNil(machines.first?.imagePath)
    }
}