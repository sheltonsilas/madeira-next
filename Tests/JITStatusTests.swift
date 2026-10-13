import XCTest
@testable import MadeiraNext

final class JITStatusTests: XCTestCase {

    func testTheMappingDecidesAndTheDebuggerAloneDoesNot() {
        // A debugger can be attached and still be granted nothing, which is why
        // the mapping is the decisive probe.
        XCTAssertEqual(JITDetector.status(for: JITProbes(debuggerAttached: false,
                                                        executableMemoryAvailable: true)), .on)
        XCTAssertEqual(JITDetector.status(for: JITProbes(debuggerAttached: true,
                                                        executableMemoryAvailable: true)), .on)
    }

    func testNoDebuggerAndNoMappingIsReportedAsTheDebugger() {
        XCTAssertEqual(JITDetector.status(for: .none), .off(.debuggerNotAttached))
    }

    func testADebuggerWithNoMappingIsReportedAsTheMapping() {
        XCTAssertEqual(
            JITDetector.status(for: JITProbes(debuggerAttached: true, executableMemoryAvailable: false)),
            .off(.executableMemoryRefused))
    }

    func testEachReasonSaysWhatWouldFixIt() {
        // The explanations are what the user reads. One that does not name the
        // entitlement or the tool is a status with no value.
        XCTAssertTrue(JITOffReason.debuggerNotAttached.explanation.contains("get-task-allow"))
        XCTAssertTrue(JITOffReason.debuggerNotAttached.explanation.contains("allow-jit"))
        XCTAssertTrue(JITOffReason.executableMemoryRefused.explanation.contains("allow-jit"))
    }

    func testTheProbeAnswersRatherThanCrashingAndUsesMapJITsOwnFlag() {
        // The value depends on the host; what is checked is that the probe runs
        // and that the flag is the real one, because a wrong flag reports
        // "refused" on a build that is fine.
        _ = JITProbes.read()
        XCTAssertEqual(JITDetector.mapJIT, 0x0800)
    }

    func testReasonsAreDistinctSoTheUIChoosesOne() {
        XCTAssertNotEqual(JITOffReason.debuggerNotAttached, JITOffReason.executableMemoryRefused)
    }

    // MARK: Guest memory

    func testMemoryIsSaidToBeSafeAtOrBelowTheUnentitledLimit() {
        XCTAssertNil(CapabilityReport.memoryWarning(guestMegabytes: 512, physicalMemory: 8 << 30))
        XCTAssertNil(CapabilityReport.memoryWarning(
            guestMegabytes: CapabilityReport.unentitledGuestLimitMB, physicalMemory: 8 << 30))
    }

    func testTheMemoryWarningNamesTheGuestSizeTheEntitlementAndASafeSize() throws {
        let warning = try XCTUnwrap(
            CapabilityReport.memoryWarning(guestMegabytes: 2048, physicalMemory: 6 << 30))
        XCTAssertTrue(warning.contains("2048"))
        XCTAssertTrue(warning.contains("increased-memory-limit"))
        XCTAssertTrue(warning.contains("1024"))
    }

    func testTheDefaultGuestSizeIsWarnedAboutBecauseItIsTheCommonCase() {
        let machine = Machine(name: "m", memoryMB: 2048, cpuCount: 2)
        let rows = CapabilityReport.rows(probes: .none, engine: .missing, firmware: nil,
                                         physicalMemory: 6 << 30,
                                         guestMegabytes: machine.memoryMB)
        XCTAssertEqual(rows.first { $0.title == "Guest memory" }?.isWarning, true)
    }

    func testAMissingEngineAndFirmwareAreWarningsWithTheConsequenceStated() throws {
        let rows = CapabilityReport.rows(probes: .none, engine: .missing, firmware: nil,
                                         physicalMemory: 6 << 30, guestMegabytes: nil)
        let engine = try XCTUnwrap(rows.first { $0.title == "Engine" })
        XCTAssertTrue(engine.isWarning)
        XCTAssertTrue(try XCTUnwrap(engine.detail).contains("cannot start"))
        let firmware = try XCTUnwrap(rows.first { $0.title == "UEFI firmware" })
        XCTAssertTrue(firmware.isWarning)
    }

    func testThereIsNoGuestMemoryRowWhenNoMachineIsKnown() {
        let rows = CapabilityReport.rows(probes: .none, engine: .missing, firmware: nil,
                                         physicalMemory: 0, guestMegabytes: nil)
        XCTAssertNil(rows.first { $0.title == "Guest memory" })
    }

    func testTheEngineKindIsStatedSoASlowBootIsExplained() throws {
        // This build's engine interprets. A user who has been told a boot takes
        // minutes is not looking for a bug in the app.
        let rows = CapabilityReport.rows(probes: .none, engine: .missing, firmware: nil,
                                         physicalMemory: 0, guestMegabytes: nil)
        let kind = try XCTUnwrap(rows.first { $0.title == "Engine kind" })
        XCTAssertTrue(kind.value.contains("interpreter"))
        XCTAssertFalse(kind.isWarning)
    }

    // MARK: The exit guard

    func testTheExitGuardReportsWhetherItIsArmed() {
        // Arming is per thread, so this only proves the C side answers; that the
        // guard actually intercepts needs a device, and docs/ARCHITECTURE.md says
        // so rather than pretending otherwise.
        XCTAssertFalse(EngineExitGuard.isArmed)
        EngineExitGuard.arm()
        XCTAssertTrue(EngineExitGuard.isArmed)
        EngineExitGuard.disarm()
        XCTAssertFalse(EngineExitGuard.isArmed)
    }

    func testANotedExitIsKeptUntilItIsRead() {
        EngineExitNote.record(7)
        XCTAssertEqual(EngineExitNote.peek(), 7)
        XCTAssertEqual(EngineExitNote.peek(), 7)
        XCTAssertEqual(EngineExitNote.take(), 7)
        XCTAssertNil(EngineExitNote.take())
    }
}
