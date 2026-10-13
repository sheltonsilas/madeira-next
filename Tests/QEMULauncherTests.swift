import XCTest
@testable import MadeiraNext

final class QEMULauncherTests: XCTestCase {
    private let firmware = LinuxFirmware(
        code: URL(fileURLWithPath: "/share/qemu/edk2-aarch64-code.fd"),
        vars: URL(fileURLWithPath: "/share/qemu/edk2-arm-vars.fd"))
    private let share = URL(fileURLWithPath: "/share")

    private func args(machine: Machine = Machine(name: "m", memoryMB: 2048, cpuCount: 2),
                      image: String = "/disk/ubuntu.qcow2",
                      format: String? = nil,
                      installDisk: String? = nil,
                      vars: URL? = URL(fileURLWithPath: "/disk/efi-vars.fd")) -> [String] {
        QEMUArguments.build(machine: machine, imagePath: image, firmware: firmware,
                            writableVars: vars, shareDirectory: share,
                            monitorPath: "/disk/monitor.sock", consolePath: "/disk/console.sock",
                            imageFormat: format, installDiskPath: installDisk)
    }

    private func windowsArgs(image: String = "/disk/windows.iso",
                             format: String? = "iso",
                             installDisk: String? = nil) -> [String] {
        let machine = Machine(name: "w", guest: .windows, memoryMB: 4096, cpuCount: 2)
        return args(machine: machine, image: image, format: format, installDisk: installDisk)
    }

    // MARK: The machine itself

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

    // MARK: Linux media

    func testALinuxDiskIsAVirtioDisk() {
        let a = args(image: "/d/x.qcow2", format: "qcow2")
        XCTAssertTrue(a.contains("file=/d/x.qcow2,if=none,id=hd0,format=qcow2,cache=writeback"))
        XCTAssertTrue(a.contains("virtio-blk-pci,drive=hd0"))
        XCTAssertFalse(a.contains("virtio-scsi-pci,id=scsi0"))
    }

    func testALinuxInstallerIsACDOnAVirtioScsiController() {
        let a = args(image: "/d/ubuntu.iso", format: "iso")
        XCTAssertTrue(a.contains("file=/d/ubuntu.iso,if=none,id=cd0,format=raw,media=cdrom,readonly=on"))
        XCTAssertTrue(a.contains("virtio-scsi-pci,id=scsi0"))
        XCTAssertTrue(a.contains("scsi-cd,drive=cd0,bus=scsi0.0"))
    }

    func testAnInstallDiskIsAttachedBesideTheInstaller() {
        // An installer with nowhere to install to is the case that looks like a
        // working machine and is not.
        let a = args(image: "/d/ubuntu.iso", format: "iso", installDisk: "/d/install.raw")
        XCTAssertTrue(a.contains("file=/d/install.raw,if=none,id=vd0,format=raw,cache=writeback"))
        XCTAssertTrue(a.contains("virtio-blk-pci,drive=vd0"))
        XCTAssertTrue(a.contains("file=/d/ubuntu.iso,if=none,id=cd0,format=raw,media=cdrom,readonly=on"))
    }

    func testAnImageNamedImgIsNotAssumedToBeRawWhenTheBytesSayQcow2() {
        XCTAssertEqual(QEMUArguments.format(for: "/d/cloud.img", recorded: "qcow2"), "qcow2")
        XCTAssertEqual(QEMUArguments.format(for: "/d/x.qcow2", recorded: nil), "qcow2")
        XCTAssertEqual(QEMUArguments.format(for: "/d/x.iso", recorded: nil), "iso")
        XCTAssertEqual(QEMUArguments.format(for: "/d/x.img", recorded: nil), "raw")
        XCTAssertEqual(QEMUArguments.format(for: "/d/x.raw", recorded: "RAW"), "raw")
    }

    // MARK: Windows media

    func testAWindowsMachineGetsUsbStorageAndNoVirtioAtAll() {
        // Windows ARM64 has USB mass storage and xHCI in the box, and no virtio
        // driver at all: a virtio disk is a disk Windows cannot see.
        let a = windowsArgs()
        XCTAssertTrue(a.contains("qemu-xhci,id=xhci"))
        XCTAssertTrue(a.contains("file=/disk/windows.iso,if=none,id=cd0,format=raw,media=cdrom,readonly=on"))
        XCTAssertTrue(a.contains("usb-storage,drive=cd0,bus=xhci.0"))
        XCTAssertFalse(a.contains { $0.contains("virtio") })
    }

    func testAWindowsInstallDiskIsUsbStorageToo() {
        let a = windowsArgs(installDisk: "/disk/windows.raw")
        XCTAssertTrue(a.contains("file=/disk/windows.raw,if=none,id=wd0,format=raw,cache=writeback"))
        XCTAssertTrue(a.contains("usb-storage,drive=wd0,bus=xhci.0"))
    }

    func testAWindowsDiskImageIsAttachedAsAUsbDisk() {
        let a = windowsArgs(image: "/disk/windows.qcow2", format: "qcow2")
        XCTAssertTrue(a.contains("file=/disk/windows.qcow2,if=none,id=hd0,format=qcow2,cache=writeback"))
        XCTAssertTrue(a.contains("usb-storage,drive=hd0,bus=xhci.0"))
    }

    // MARK: Paths QEMU's option parser cannot take

    func testAPathWithACommaUsesBlockdevJsonInsteadOfTheDriveShorthand() {
        // -drive takes a comma-separated option string with no escape for a comma
        // inside a value, so a file named with one cannot be named there: QEMU
        // reads the rest of the name as options and refuses the machine, which in
        // this app used to mean the app terminating.
        let a = args(image: "/d/ub,untu.iso", format: "iso")
        XCTAssertFalse(a.contains { $0.hasPrefix("file=/d/ub,untu.iso") })
        XCTAssertTrue(a.contains { $0.contains("\"filename\":\"/d/ub,untu.iso\"") })
        XCTAssertTrue(a.contains { $0.contains("\"node-name\":\"cd0-file\"") })
        XCTAssertTrue(a.contains { $0.contains("\"driver\":\"raw\"") })
        XCTAssertTrue(a.contains("scsi-cd,drive=cd0,bus=scsi0.0"))
        XCTAssertFalse(a.contains("-drive") && a.contains { $0.contains("/d/ub,untu.iso") && $0.hasPrefix("file=") })
    }

    func testAPlainPathStillUsesTheReadableShorthand() {
        // The JSON form is for the paths that need it; everything else stays in
        // the form the boot smoke and every guide uses.
        let a = args(image: "/d/plain.qcow2", format: "qcow2")
        XCTAssertFalse(a.contains("-blockdev"))
    }

    // MARK: What stops a start, and what only gets said

    func testAMissingImageIsNamedForBothGuests() throws {
        let linux = try XCTUnwrap(LinuxBootCheck.mediumProblem(imagePath: nil, guest: .linux, diskPath: nil))
        XCTAssertTrue(linux.contains("No disk image"))
        let windows = try XCTUnwrap(LinuxBootCheck.mediumProblem(imagePath: nil, guest: .windows, diskPath: nil))
        XCTAssertTrue(windows.contains("UUP"))
    }

    func testAnImageThatIsGoneOrEmptyIsNamed() throws {
        let gone = try XCTUnwrap(LinuxBootCheck.mediumProblem(imagePath: "/definitely/not/here.qcow2",
                                                              guest: .linux, diskPath: nil))
        XCTAssertTrue(gone.contains("no longer at"))

        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        let problem = try XCTUnwrap(LinuxBootCheck.mediumProblem(imagePath: empty.path, guest: .linux, diskPath: nil))
        XCTAssertTrue(problem.contains("empty"))
    }

    func testAnInstallDiskThatIsGoneIsNamedButOnlyWhenOneIsRecorded() throws {
        let image = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0x00]).write(to: image)
        defer { try? FileManager.default.removeItem(at: image) }

        XCTAssertNil(LinuxBootCheck.mediumProblem(imagePath: image.path, guest: .linux, diskPath: nil))
        let problem = try XCTUnwrap(LinuxBootCheck.mediumProblem(imagePath: image.path, guest: .linux,
                                                                 diskPath: "/definitely/not/here.raw"))
        XCTAssertTrue(problem.contains("gone"))
    }

    func testAnInstallerWithNoInstallDiskIsWarnedAboutNotRefused() throws {
        // Refusing would be the app overruling a user who may want exactly this.
        let iso = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iso")
        try Data([0x00, 0x01]).write(to: iso)
        defer { try? FileManager.default.removeItem(at: iso) }

        let machine = Machine(name: "installer", memoryMB: 1024, cpuCount: 1,
                              imagePath: iso.path, imageFormat: "iso")
        XCTAssertNil(LinuxBootCheck.mediumProblem(imagePath: machine.imagePath, guest: .linux, diskPath: nil))
        let warnings = LinuxBootCheck.warnings(for: machine, physicalMemory: 8 << 30)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(try XCTUnwrap(warnings.first).contains("install disk"))
    }

    func testAnInstallDiskSilencesTheInstallerWarning() throws {
        let iso = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iso")
        let disk = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".raw")
        try Data([0x00, 0x01]).write(to: iso)
        try Data(repeating: 0, count: 1024).write(to: disk)
        defer {
            try? FileManager.default.removeItem(at: iso)
            try? FileManager.default.removeItem(at: disk)
        }

        var machine = Machine(name: "installer", memoryMB: 1024, cpuCount: 1,
                              imagePath: iso.path, imageFormat: "iso")
        machine.diskPath = disk.path
        XCTAssertEqual(LinuxBootCheck.warnings(for: machine, physicalMemory: 8 << 30), [])
    }

    func testAWindowsMachineIsWarnedAboutTheTpmAndAboutItsMemory() throws {
        let iso = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iso")
        try Data([0x00, 0x01]).write(to: iso)
        defer { try? FileManager.default.removeItem(at: iso) }

        let machine = Machine(name: "windows", guest: .windows, memoryMB: 2048, cpuCount: 1,
                              imagePath: iso.path, imageFormat: "iso")
        let warnings = LinuxBootCheck.warnings(for: machine, physicalMemory: 6 << 30)
        XCTAssertTrue(warnings.contains { $0.contains("TPM") }, "the Secure Boot and TPM refusal has to be said")
        XCTAssertTrue(warnings.contains { $0.contains("4096") }, "the suggested Windows size has to be said")
        XCTAssertTrue(warnings.contains { $0.contains("increased-memory-limit") })
    }

    // MARK: The boot smoke

    /// Publishes the argument vectors for tools/boot_smoke.py to boot a guest
    /// with.
    ///
    /// This is the only route the argv has out of the app, and it is deliberately
    /// the real builder rather than a copy kept in step by hand: the smoke script
    /// reads the JSON between these markers out of the xcodebuild log and runs a
    /// guest with exactly what QEMUArguments.build produced here. Paths are under
    /// /MADEIRA_SMOKE, which the script rewrites to its own working directory.
    ///
    /// The Linux vector stays first and unlabelled, because that is the block the
    /// script parses and boots. The Windows vector follows under its own markers
    /// so its device choice is recorded in the same log and available to a later
    /// run, without changing what the scheduled smoke boots.
    func testArgumentVectorForTheBootSmoke() throws {
        let machine = Machine(name: "smoke", memoryMB: 1024, cpuCount: 1)
        let argv = QEMUArguments.build(
            machine: machine,
            imagePath: "/MADEIRA_SMOKE/disk.raw",
            firmware: LinuxFirmware(
                code: URL(fileURLWithPath: "/MADEIRA_SMOKE/share/qemu/edk2-aarch64-code.fd"),
                vars: URL(fileURLWithPath: "/MADEIRA_SMOKE/share/qemu/edk2-arm-vars.fd")),
            writableVars: URL(fileURLWithPath: "/MADEIRA_SMOKE/efi-vars.fd"),
            shareDirectory: URL(fileURLWithPath: "/MADEIRA_SMOKE/share"),
            monitorPath: "/MADEIRA_SMOKE/monitor.sock",
            consolePath: "/MADEIRA_SMOKE/console.sock")

        // withoutEscapingSlashes matters: the default escapes every "/" as "\/",
        // which the parser would undo and which made the first version of this
        // test fail on an assertion about its own output.
        let data = try JSONSerialization.data(
            withJSONObject: argv, options: [.sortedKeys, .withoutEscapingSlashes])
        let json = String(decoding: data, as: UTF8.self)
        // A vector that no longer mentions the placeholder paths would let the
        // smoke test boot something other than what this builder makes.
        XCTAssertTrue(json.contains("/MADEIRA_SMOKE/console.sock"))
        XCTAssertTrue(json.contains("qemu-system-aarch64"))
        print("MADEIRA-ARGV-BEGIN")
        print(json)
        print("MADEIRA-ARGV-END")

        let windows = QEMUArguments.build(
            machine: Machine(name: "smoke-windows", guest: .windows, memoryMB: 4096, cpuCount: 2),
            imagePath: "/MADEIRA_SMOKE/windows.iso",
            firmware: LinuxFirmware(
                code: URL(fileURLWithPath: "/MADEIRA_SMOKE/share/qemu/edk2-aarch64-code.fd"),
                vars: URL(fileURLWithPath: "/MADEIRA_SMOKE/share/qemu/edk2-arm-vars.fd")),
            writableVars: URL(fileURLWithPath: "/MADEIRA_SMOKE/efi-vars.fd"),
            shareDirectory: URL(fileURLWithPath: "/MADEIRA_SMOKE/share"),
            monitorPath: "/MADEIRA_SMOKE/monitor.sock",
            consolePath: "/MADEIRA_SMOKE/console.sock",
            imageFormat: "iso",
            installDiskPath: "/MADEIRA_SMOKE/windows.raw")

        let windowsData = try JSONSerialization.data(
            withJSONObject: windows, options: [.sortedKeys, .withoutEscapingSlashes])
        let windowsJSON = String(decoding: windowsData, as: UTF8.self)
        XCTAssertTrue(windowsJSON.contains("qemu-xhci"))
        XCTAssertTrue(windowsJSON.contains("/MADEIRA_SMOKE/windows.iso"))
        print("MADEIRA-ARGV-WINDOWS-BEGIN")
        print(windowsJSON)
        print("MADEIRA-ARGV-WINDOWS-END")
    }
}
