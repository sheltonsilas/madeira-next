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
}
