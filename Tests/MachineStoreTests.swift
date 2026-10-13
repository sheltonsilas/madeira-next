import XCTest
@testable import MadeiraNext

final class MachineValidationTests: XCTestCase {
    func testTrimsNameAndKeepsValidValues() throws {
        let machine = try Machine(name: "  Ubuntu  ", memoryMB: 2048, cpuCount: 2).validated()
        XCTAssertEqual(machine.name, "Ubuntu")
        XCTAssertEqual(machine.memoryMB, 2048)
        XCTAssertEqual(machine.cpuCount, 2)
    }

    func testRejectsEmptyName() {
        XCTAssertThrowsError(try Machine(name: "   ", memoryMB: 2048, cpuCount: 2).validated()) { error in
            XCTAssertEqual(error as? MachineValidationError, .emptyName)
        }
    }

    func testRejectsMemoryOutsideRange() {
        XCTAssertThrowsError(try Machine(name: "a", memoryMB: 256, cpuCount: 2).validated()) { error in
            XCTAssertEqual(error as? MachineValidationError, .memoryOutOfRange)
        }
        XCTAssertThrowsError(try Machine(name: "a", memoryMB: 9000, cpuCount: 2).validated()) { error in
            XCTAssertEqual(error as? MachineValidationError, .memoryOutOfRange)
        }
    }

    func testRejectsCPUOutsideRange() {
        XCTAssertThrowsError(try Machine(name: "a", memoryMB: 2048, cpuCount: 0).validated()) { error in
            XCTAssertEqual(error as? MachineValidationError, .cpuOutOfRange)
        }
    }
}

final class MachineStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> MachineStore {
        MachineStore(fileURL: directory.appendingPathComponent("machines.json"))
    }

    func testMissingFileLoadsAsEmpty() throws {
        XCTAssertEqual(try makeStore().load(), [])
    }

    func testRoundTripKeepsEveryField() throws {
        let store = makeStore()
        let machines = [
            Machine(name: "Ubuntu", memoryMB: 2048, cpuCount: 2),
            Machine(name: "Debian", memoryMB: 1024, cpuCount: 1),
        ]
        try store.save(machines)
        XCTAssertEqual(try store.load(), machines)
    }

    func testCorruptFileThrowsInsteadOfLosingMachines() throws {
        let file = directory.appendingPathComponent("machines.json")
        try Data("not json".utf8).write(to: file)
        XCTAssertThrowsError(try MachineStore(fileURL: file).load())
    }

    func testRoundTripKeepsTheGuestAndBothMedia() throws {
        let store = makeStore()
        var machine = Machine(name: "Windows", guest: .windows, memoryMB: 4096, cpuCount: 2)
        machine.imagePath = "/machines/1/windows.iso"
        machine.imageFormat = "iso"
        machine.diskPath = "/machines/1/install.raw"
        try store.save([machine])
        let loaded = try store.load()
        XCTAssertEqual(loaded.first?.guest, .windows)
        XCTAssertEqual(loaded.first?.imageFormat, "iso")
        XCTAssertEqual(loaded.first?.diskPath, "/machines/1/install.raw")
    }

    func testAFileWrittenBeforeGuestsExistedStillLoads() throws {
        // Losing a user's machines to a schema change is the one failure mode a
        // store may not have, so every field added since is decoded as optional
        // or with a default.
        let file = directory.appendingPathComponent("machines.json")
        let json = #"[{"id":"\#(UUID().uuidString)","name":"old","memoryMB":1024,"cpuCount":1,"imagePath":"/x/y.qcow2"}]"#
        try Data(json.utf8).write(to: file)

        let machines = try MachineStore(fileURL: file).load()
        XCTAssertEqual(machines.count, 1)
        XCTAssertEqual(machines.first?.guest, .linux, "a machine from before guests existed is a Linux machine")
        XCTAssertNil(machines.first?.imageFormat)
        XCTAssertNil(machines.first?.diskPath)
        XCTAssertEqual(machines.first?.imagePath, "/x/y.qcow2")
    }

    func testTheGuestDefaultsToLinuxInTheForm() {
        XCTAssertEqual(Machine(name: "m", memoryMB: 2048, cpuCount: 2).guest, .linux)
        XCTAssertEqual(GuestKind.allCases.count, 2)
        XCTAssertEqual(GuestKind.windows.title, "Windows (ARM64)")
    }
}
