import XCTest
@testable import MadeiraNext

final class EngineLocatorTests: XCTestCase {
    private var frameworks: URL!

    override func setUpWithError() throws {
        frameworks = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: frameworks)
    }

    func testFindsTheBinaryInsideTheFramework() throws {
        let framework = frameworks.appendingPathComponent("\(EngineLocator.frameworkName).framework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let binary = framework.appendingPathComponent(EngineLocator.frameworkName)
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: binary)

        XCTAssertEqual(EngineLocator.binary(in: frameworks), binary)
    }

    func testReportsNothingWhenTheFrameworkIsAbsent() {
        XCTAssertNil(EngineLocator.binary(in: frameworks))
    }

    func testReportsNothingWhenTheDirectoryDoesNotExist() {
        let missing = frameworks.appendingPathComponent("nope", isDirectory: true)
        XCTAssertNil(EngineLocator.binary(in: missing))
    }
}
