import Foundation
import Darwin

/// The UEFI firmware pair the launcher boots with.
struct LinuxFirmware: Equatable {
    let code: URL
    let vars: URL?
}

/// Builds QEMU's argument vector for one machine. Pure: it touches no files and
/// no engine, so it can be unit-tested on any host and the same builder is what
/// the nightly boot smoke runs a guest with.
enum QEMUArguments {
    /// The devices a guest's disks are attached to.
    ///
    /// This is the one place the guest kind decides anything, and it has to: Linux
    /// cloud images have virtio drivers and no USB mass-storage driver, while
    /// Windows ARM64 is the other way round. Attaching either disk the other way
    /// gives a guest that cannot see its own disk.
    enum Attachment: Equatable {
        /// A Linux boot disk: virtio-blk on the virtio-mmio-free PCI transport.
        case virtioDisk
        /// A Linux install medium: a CD on a virtio-scsi controller.
        case virtioCD
        /// Anything a Windows guest sees: USB mass storage behind xHCI, which is
        /// in Windows ARM64's in-box driver set.
        case usbStorage
    }

    static func build(machine: Machine,
                      imagePath: String,
                      firmware: LinuxFirmware,
                      writableVars: URL?,
                      shareDirectory: URL,
                      monitorPath: String,
                      consolePath: String,
                      imageFormat: String? = nil,
                      installDiskPath: String? = nil) -> [String] {
        var a = ["qemu-system-aarch64", "-M", "virt"]
        // Interpreter-only builds have no multi-threaded TCG, so single-threaded
        // TCG is the only accelerator this engine is asked for.
        a += ["-accel", "tcg,thread=single"]
        a += ["-cpu", "max"]
        a += ["-smp", String(max(1, machine.cpuCount))]
        a += ["-m", String(max(512, machine.memoryMB))]

        let format = QEMUArguments.format(for: imagePath, recorded: imageFormat)
        let isISO = format == "iso"

        switch machine.guest {
        case .linux:
            if isISO {
                // media=cdrom with readonly=on, because an installer's own kernel
                // writes back to a disc it has mounted. virtio-blk would report
                // the media as non-removable and the ISO as an ordinary disk.
                a += attach(path: imagePath, format: "raw", node: "cd0",
                            attachment: .virtioCD, readOnly: true, media: "cdrom")
            } else {
                a += attach(path: imagePath, format: format, node: "hd0",
                            attachment: .virtioDisk, readOnly: false, media: nil)
            }
            if let installDiskPath {
                // The disk an installer writes to. Its own node, because a CD and
                // a disk on the same controller are two devices.
                a += attach(path: installDiskPath, format: "raw", node: "vd0",
                            attachment: .virtioDisk, readOnly: false, media: nil)
            }
        case .windows:
            // xHCI first: usb-storage needs a USB bus to sit on, and the virt
            // machine has none until one is asked for.
            a += ["-device", "qemu-xhci,id=xhci"]
            if isISO {
                a += attach(path: imagePath, format: "raw", node: "cd0",
                            attachment: .usbStorage, readOnly: true, media: "cdrom")
            } else {
                a += attach(path: imagePath, format: format, node: "hd0",
                            attachment: .usbStorage, readOnly: false, media: nil)
            }
            if let installDiskPath {
                a += attach(path: installDiskPath, format: "raw", node: "wd0",
                            attachment: .usbStorage, readOnly: false, media: nil)
            }
        }

        a += ["-drive", "if=pflash,format=raw,readonly=on,file=\(firmware.code.path)"]
        if let writableVars {
            a += ["-drive", "if=pflash,format=raw,file=\(writableVars.path)"]
        }

        a += ["-display", "none"]
        // Input devices follow the same rule as disks: a guest only has a driver
        // for the ones its platform ships with.
        if machine.guest == .linux {
            a += ["-device", "virtio-keyboard-pci", "-device", "virtio-tablet-pci"]
        } else {
            a += ["-device", "usb-kbd", "-device", "usb-tablet"]
        }
        a += ["-chardev", "socket,id=madeira-console,path=\(consolePath),server=on,wait=off"]
        a += ["-serial", "chardev:madeira-console"]
        a += ["-chardev", "socket,id=madeira-monitor,path=\(monitorPath),server=on,wait=off"]
        a += ["-monitor", "chardev:madeira-monitor"]
        a += ["-L", shareDirectory.appendingPathComponent("qemu").path]
        return a
    }

    /// How a medium is read: what the machine recorded, or the file name's
    /// extension as a fallback for a machine saved before it was recorded.
    ///
    /// A file called `.img` is not necessarily raw - Ubuntu's cloud images are
    /// qcow2 inside one - which is why the recorded value wins and why
    /// `MachineImage.format(atPath:recorded:)` sniffs a file whose format nobody
    /// wrote down.
    static func format(for path: String, recorded: String?) -> String {
        if let recorded, !recorded.isEmpty { return recorded.lowercased() }
        let lower = path.lowercased()
        if lower.hasSuffix(".iso") { return "iso" }
        if lower.hasSuffix(".qcow2") { return "qcow2" }
        return "raw"
    }

    /// One disk, as the `-drive` shorthand or, when the path contains a comma,
    /// the `-blockdev` form.
    ///
    /// `-drive` takes a comma-separated option string with no way to escape a
    /// comma inside a value, so a file whose name holds one cannot be named there
    /// at all: QEMU reads the rest of the name as further options and refuses the
    /// machine, which inside this app is the app terminating (see
    /// App/EngineExitGuard.c). `-blockdev` takes JSON, where a comma is just a
    /// character. So the JSON form is used only for the paths that need it, and
    /// the plain form - the one the boot smoke exercises - everywhere else.
    static func attach(path: String, format: String, node: String,
                       attachment: Attachment, readOnly: Bool, media: String?) -> [String] {
        let device: String
        let bus: String?
        switch attachment {
        case .virtioDisk: device = "virtio-blk-pci"; bus = nil
        case .virtioCD: device = "scsi-cd"; bus = "scsi0.0"
        case .usbStorage: device = "usb-storage"; bus = "xhci.0"
        }

        if path.contains(",") {
            let fileNode = node + "-file"
            var fileOptions: [String: Any] = ["driver": "file", "filename": path, "node-name": fileNode]
            if readOnly { fileOptions["read-only"] = true }
            var formatOptions: [String: Any] = ["driver": format, "file": fileNode, "node-name": node]
            if readOnly { formatOptions["read-only"] = true }
            var args: [String] = []
            // A CD on the virtio-scsi controller still needs the controller.
            if attachment == .virtioCD { args += ["-device", "virtio-scsi-pci,id=scsi0"] }
            args += ["-blockdev", json(fileOptions), "-blockdev", json(formatOptions)]
            args += ["-device", describe(device: device, node: node, bus: bus)]
            return args
        }

        var options = "file=\(path),if=none,id=\(node),format=\(format)"
        if let media { options += ",media=\(media)" }
        options += readOnly ? ",readonly=on" : ",cache=writeback"
        var args: [String] = []
        if attachment == .virtioCD { args += ["-device", "virtio-scsi-pci,id=scsi0"] }
        args += ["-drive", options]
        args += ["-device", describe(device: device, node: node, bus: bus)]
        return args
    }

    private static func describe(device: String, node: String, bus: String?) -> String {
        var text = "\(device),drive=\(node)"
        if let bus { text += ",bus=\(bus)" }
        return text
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// Finds the engine, its firmware, and reports what is missing by name.
enum LinuxBootCheck {
    /// The bundle's `share/` directory, where the packaging step puts QEMU's data.
    static var shareDirectory: URL? {
        Bundle.main.bundleURL.appendingPathComponent("share", isDirectory: true)
    }

    static let firmwareCode = "qemu/edk2-aarch64-code.fd"
    static let firmwareVars = "qemu/edk2-arm-vars.fd"

    /// The firmware pair, or nil when the code image is missing.
    static func firmware() -> LinuxFirmware? {
        guard let share = shareDirectory else { return nil }
        let fm = FileManager.default
        let code = share.appendingPathComponent(firmwareCode)
        guard fm.fileExists(atPath: code.path) else { return nil }
        let vars = share.appendingPathComponent(firmwareVars)
        return LinuxFirmware(code: code, vars: fm.fileExists(atPath: vars.path) ? vars : nil)
    }

    /// The engine binary inside the app bundle, or nil.
    static func engineURL() -> URL? {
        guard case .available(let url) = EngineLocator.status() else { return nil }
        return url
    }

    /// Why this machine cannot start at all, or nil when it can.
    ///
    /// Only things that stop a start are here. Anything a guest could survive -
    /// an installer with no install disk, a guest larger than the app's memory
    /// entitlement - is in `warnings(for:physicalMemory:)` instead, because
    /// refusing to start a machine the user may have deliberately configured is a
    /// worse failure than starting it and saying what to watch for.
    static func blocker(for machine: Machine) -> String? {
        guard engineURL() != nil else {
            return "This build has no engine, so machines cannot start."
        }
        guard firmware() != nil else {
            return "This build has no UEFI firmware (share/\(firmwareCode)), so the machine cannot boot."
        }
        return mediumProblem(imagePath: machine.imagePath, guest: machine.guest, diskPath: machine.diskPath)
    }

    /// The checks that look at the filesystem rather than the bundle, so they can
    /// be tested where no engine is installed - which is every simulator test.
    static func mediumProblem(imagePath: String?, guest: GuestKind, diskPath: String?) -> String? {
        guard let imagePath else {
            return guest == .windows
                ? "No Windows image is set for this machine yet. Assemble one from a UUP dump and add it with Choose disk image."
                : "No disk image is set for this machine yet."
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: imagePath) else {
            return "The disk image is no longer at \(imagePath)."
        }
        let size = (try? fm.attributesOfItem(atPath: imagePath)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            return "The image at \(imagePath) is empty, so there is nothing to boot."
        }
        if let diskPath, !fm.fileExists(atPath: diskPath) {
            return "The install disk for this machine is gone from \(diskPath)."
        }
        return nil
    }

    /// What is worth saying before a start, in the order the console should say it.
    static func warnings(for machine: Machine,
                         physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> [String] {
        var warnings: [String] = []

        if machine.guest == .windows {
            if machine.memoryMB < Machine.windowsSuggestedMemoryMB {
                warnings.append("Windows with \(machine.memoryMB) MB of RAM will be very slow, if setup gets that far. \(Machine.windowsSuggestedMemoryMB) MB is the usual minimum.")
            }
            // The TPM and Secure Boot sentence, because it is the one thing a
            // Windows 11 install refuses on and nothing in this app can provide
            // either.
            warnings.append(WindowsImageGuidance.steps[1])
        }

        if let source = machine.imagePath {
            let format = MachineImage.format(atPath: source, recorded: machine.imageFormat)
            if format == "iso", machine.diskPath == nil {
                warnings.append("The medium is an installer and this machine has no install disk, so setup has nowhere to install to. Create install disk in the machine's menu makes one; without it the installer will run and find no disk.")
            }
            if format == "raw", MachineImage.sniffFormat(atPath: source) == "qcow2" {
                warnings.append("The file is a qcow2 image uploaded before the format was recorded. Attach it as a Linux disk with the right format or record it again, because raw and qcow2 read the same bytes very differently.")
            }
        }

        if let memoryWarning = CapabilityReport.memoryWarning(guestMegabytes: machine.memoryMB,
                                                             physicalMemory: physicalMemory) {
            warnings.append(memoryWarning)
        }

        return warnings
    }
}

/// Loads the engine with dlopen and runs it on its own thread.
struct QEMUEngine {
    typealias Init = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
    typealias MainLoop = @convention(c) () -> Void
    typealias Cleanup = @convention(c) () -> Void

    let initialize: Init
    let mainLoop: MainLoop
    let cleanup: Cleanup

    /// Loads the three entry points QEMU's shared library exports.
    static func load(at url: URL) throws -> QEMUEngine {
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            let why = dlerror().map { String(cString: $0) } ?? "no reason given"
            throw EngineError.loadFailed(why)
        }
        func symbol(_ name: String) throws -> UnsafeMutableRawPointer {
            guard let p = dlsym(handle, name) else { throw EngineError.missingSymbol(name) }
            return p
        }
        return QEMUEngine(
            initialize: unsafeBitCast(try symbol("qemu_init"), to: Init.self),
            mainLoop: unsafeBitCast(try symbol("qemu_main_loop"), to: MainLoop.self),
            cleanup: unsafeBitCast(try symbol("qemu_cleanup"), to: Cleanup.self))
    }

    /// Runs the engine to completion. Argument strings are intentionally not
    /// freed: QEMU keeps pointers into them until qemu_cleanup returns.
    ///
    /// It can also not return - QEMU's own failure path is `exit(1)`, which
    /// App/EngineExitGuard.c intercepts on this thread so the app stays alive to
    /// report it.
    func run(argv: [String]) {
        let cStrings: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let vector = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: cStrings.count)
        for (i, s) in cStrings.enumerated() { vector[i] = s }
        initialize(Int32(argv.count), vector)
        mainLoop()
        cleanup()
    }

    enum EngineError: LocalizedError {
        case loadFailed(String)
        case missingSymbol(String)

        var errorDescription: String? {
            switch self {
            case .loadFailed(let why): return "The engine would not load: \(why)"
            case .missingSymbol(let name): return "The engine does not export \(name)."
            }
        }
    }
}
