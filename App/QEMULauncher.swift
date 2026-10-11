import Foundation
import Darwin

/// The UEFI firmware pair the launcher boots with.
struct LinuxFirmware: Equatable {
    let code: URL
    let vars: URL?
}

/// Builds QEMU's argument vector for one machine. Pure: it touches no files and
/// no engine, so it can be unit-tested on any host.
enum QEMUArguments {
    /// The machine's serial console and monitor are Unix sockets in its folder.
    static func build(machine: Machine, imagePath: String, firmware: LinuxFirmware,
                      writableVars: URL?, shareDirectory: URL,
                      monitorPath: String, consolePath: String) -> [String] {
        var a = ["qemu-system-aarch64", "-M", "virt"]
        // Interpreter-only builds have no multi-threaded TCG, so single-threaded
        // TCG is the only accelerator this engine is asked for.
        a += ["-accel", "tcg,thread=single"]
        a += ["-cpu", "max"]
        a += ["-smp", String(max(1, machine.cpuCount))]
        a += ["-m", String(max(512, machine.memoryMB))]

        let lower = imagePath.lowercased()
        if lower.hasSuffix(".iso") {
            a += ["-drive", "file=\(imagePath),if=none,id=cd0,format=raw,media=cdrom,readonly=on"]
            a += ["-device", "virtio-scsi-pci,id=scsi0"]
            a += ["-device", "scsi-cd,bus=scsi0.0,drive=cd0"]
        } else {
            let format = lower.hasSuffix(".qcow2") ? "qcow2" : "raw"
            a += ["-drive", "file=\(imagePath),if=virtio,format=\(format),cache=writeback"]
        }

        a += ["-drive", "if=pflash,format=raw,readonly=on,file=\(firmware.code.path)"]
        if let writableVars {
            a += ["-drive", "if=pflash,format=raw,file=\(writableVars.path)"]
        }

        a += ["-display", "none"]
        a += ["-device", "virtio-keyboard-pci", "-device", "virtio-tablet-pci"]
        a += ["-chardev", "socket,id=madeira-console,path=\(consolePath),server=on,wait=off"]
        a += ["-serial", "chardev:madeira-console"]
        a += ["-chardev", "socket,id=madeira-monitor,path=\(monitorPath),server=on,wait=off"]
        a += ["-monitor", "chardev:madeira-monitor"]
        a += ["-L", shareDirectory.appendingPathComponent("qemu").path]
        return a
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

    /// Why a machine cannot start yet, or nil when it can.
    static func blocker(imagePath: String?) -> String? {
        guard engineURL() != nil else {
            return "This build has no Linux engine, so machines cannot start."
        }
        guard firmware() != nil else {
            return "This build has no UEFI firmware (share/\(firmwareCode)), so the machine cannot boot."
        }
        guard let imagePath else {
            return "No disk image is set for this machine yet."
        }
        guard FileManager.default.fileExists(atPath: imagePath) else {
            return "The disk image is no longer at \(imagePath)."
        }
        return nil
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
