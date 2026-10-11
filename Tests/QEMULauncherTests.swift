import XCTest
@testable import MadeiraNext

final class QEMULauncherTests: XCTestCase {
    private let firmware = LinuxFirmware(
        code: URL(fileURLWithPath: "/share/qemu/edk2-aarch64-code.fd"),
        vars: URL(fileURLWithPath: "/share/qemu/edk2-arm-vars.fd"))
    private let share = URL(fileURLWithPath: "/share")

    private func args(machine: Machine = Machine(name: "m", memoryMB: 2048, cpuCount: 2),
                      image: String = "/disk/ubuntu.qcow2",
                      vars: URL? = URL(fileURLWithPath: "/disk/efi-vars.fd")) -> [String] {
        QEMUArguments.build(machine: machine, imagePath: image, firmware: firmware,
                            writableVars: vars, shareDirectory: share,
                            monitorPath: "/disk/monitor.sock", consolePath: "/disk/console.sock")
    }

    func testStartsWithTheVirtMachineAndSingleThreadedTCG() {
        let a = args()
        XCTAssertEqual(a.first, "qemu-system-aarch64")
        XCTAssertTrue(a.contains("virt"))
        XCTAssertTrue(a.contains("tcg,thread=single"))
        XCTAssertFalse(a.contains("tcg,thread=multi"))
    }

    func testCPUAndMemoryComeFromTheMachine() {
        let a = args(machine: Machine(name: "m", memoryMB: 4096, cpuCount: 4))
        XCTAssertEqual(a[a.firstIndex(of: "-smp")! + 1], "4")
        XCTAssertEqual(a[a.firstIndex(of: "-m")! + 1], "4096")
    }

    func testQcow2AndRawDiskFormats() {
        XCTAssertTrue(args(image: "/d/x.qcow2").contains("file=/d/x.qcow2,if=virtio,format=qcow2,cache=writeback"))
        XCTAssertTrue(args(image: "/d/x.img").contains("file=/d/x.img,if=virtio,format=raw,cache=writeback"))
    }

    func testIsoIsAttachedAsReadOnlyCDROM() {
        let a = args(image: "/d/ubuntu.iso")
        XCTAssertTrue(a.contains("file=/d/ubuntu.iso,if=none,id=cd0,format=raw,media=cdrom,readonly=on"))
        XCTAssertTrue(a.contains("scsi-cd,bus=scsi0.0,drive=cd0"))
    }

    func testFirmwareCodeIsReadOnlyAndVarsAreWritable() {
        let a = args()
        XCTAssertTrue(a.contains("if=pflash,format=raw,readonly=on,file=/share/qemu/edk2-aarch64-code.fd"))
        XCTAssertTrue(a.contains("if=pflash,format=raw,file=/disk/efi-vars.fd"))
    }

    func testVarsAreOmittedWhenAbsent() {
        let a = args(vars: nil)
        XCTAssertFalse(a.contains { $0.contains("efi-vars.fd") })
    }

    func testNoDisplayAndSerialAndMonitorSockets() {
        let a = args()
        XCTAssertEqual(a[a.firstIndex(of: "-display")! + 1], "none")
        XCTAssertTrue(a.contains("socket,id=madeira-console,path=/disk/console.sock,server=on,wait=off"))
        XCTAssertTrue(a.contains("socket,id=madeira-monitor,path=/disk/monitor.sock,server=on,wait=off"))
        XCTAssertEqual(a[a.firstIndex(of: "-L")! + 1], "/share/qemu")
    }

    func testBlockerReportsMissingImage() {
        XCTAssertNotNil(LinuxBootCheck.blocker(imagePath: nil))
        XCTAssertNotNil(LinuxBootCheck.blocker(imagePath: "/definitely/not/here.qcow2"))
    }
}
