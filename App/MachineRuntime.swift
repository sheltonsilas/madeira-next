import Foundation
import Darwin

/// Where one machine's own files live: its medium, its install disk, its EFI
/// variables, and the two sockets the engine is driven through.
enum MachineDirectory {
    static func root() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("MadeiraNext/Machines", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func forMachine(id: UUID) throws -> URL {
        let directory = try root().appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup(directory)
        return directory
    }

    /// Where a machine's two sockets live: a short directory at the container
    /// root, *not* beside its disk image.
    ///
    /// A Unix socket path has to fit in `sockaddr_un.sun_path`, which is 104
    /// bytes on Darwin. An app container is about 76 of those, and a machine's
    /// folder under Library/Application Support takes the full path to around
    /// 160 - so a socket created next to the image is refused with "path too
    /// long", and the machine starts with no console and a monitor that never
    /// answers. Fourteen characters under the container root leaves about eight
    /// to spare.
    static func sockets() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        // Application Support is inside Library/, so the container root is two
        // levels up: <container>/Library/Application Support.
        let container = support.deletingLastPathComponent().deletingLastPathComponent()
        let directory = container.appendingPathComponent("s", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The machine's serial console socket path; short by construction.
    static func consoleSocket(id: UUID) throws -> String {
        try sockets().appendingPathComponent("c\(tag(for: id)).sock").path
    }

    /// The machine's monitor socket path; short by construction.
    static func monitorSocket(id: UUID) throws -> String {
        try sockets().appendingPathComponent("m\(tag(for: id)).sock").path
    }

    /// The first eight hex digits of the id: enough to separate machines, short
    /// enough for the path limit.
    private static func tag(for id: UUID) -> String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    /// Keep a guest out of iCloud backups.
    ///
    /// An ISO is gigabytes and an install disk is more, and both can be fetched
    /// again; a backup that filled someone's iCloud quota with a distribution's
    /// installer would be a bug report about the wrong thing.
    private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }
}

/// Copies, adopts and creates the media a machine boots from.
enum MachineImage {
    static let extensions = ["iso", "qcow2", "img", "raw"]

    /// The size of the disk "Create install disk" makes. Big enough for a
    /// desktop install with room to spare, and sparse anyway.
    static let installDiskGigabytes = 16

    enum StorageError: LocalizedError {
        case cannotCreate(String)

        var errorDescription: String? {
            switch self {
            case .cannotCreate(let path): return "A file could not be created at \(path)."
            }
        }
    }

    /// Where an imported or downloaded image was stored, and how it must be read.
    struct Imported {
        let path: String
        let format: String
    }

    /// A file name safe to join onto a folder *and* to put on QEMU's command
    /// line: no separators, no dot-dot, and no comma, because `-drive`'s option
    /// string has no way to escape one (the launcher falls back to JSON for a
    /// comma it still finds, from a file edited by hand).
    static func sanitized(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ",", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == ".." || cleaned == "." { return "disk.img" }
        return cleaned
    }

    /// How a file is read, decided by its own first bytes.
    ///
    /// The extension is not enough: Ubuntu and Debian publish qcow2 images under
    /// a name ending in `.img`, and a qcow2 disk attached as `raw` does not boot,
    /// it reads the header as partition data. Reading four bytes is cheaper than
    /// explaining that.
    static func sniffFormat(atPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        // qcow2's magic, "QFI\xfb".
        if let head = try? handle.read(upToCount: 4), head.count == 4 {
            let bytes = [UInt8](head)
            if bytes[0] == 0x51, bytes[1] == 0x46, bytes[2] == 0x49, bytes[3] == 0xfb {
                return "qcow2"
            }
        }

        // ISO 9660 keeps "CD001" at offset 32769, which is where a bootable
        // installer's primary volume descriptor sits. Reading past the end of a
        // short file is not an error: it is simply not an ISO.
        _ = try? handle.seek(toOffset: 32769)
        if let descriptor = try? handle.read(upToCount: 5), descriptor.count == 5,
           descriptor == Data("CD001".utf8) {
            return "iso"
        }
        return "raw"
    }

    /// The format a path is read as: what the machine recorded, or what its bytes
    /// say.
    static func format(atPath path: String, recorded: String?) -> String {
        if let recorded, !recorded.isEmpty { return recorded.lowercased() }
        return sniffFormat(atPath: path) ?? "raw"
    }

    /// Import `source` for the machine, returning where it was stored and how it
    /// must be read.
    ///
    /// Copied rather than referenced: the picker hands back a security-scoped URL
    /// that is only valid for the life of the callback, and a machine whose disk
    /// image can vanish with a document provider is a machine that fails to boot
    /// once, days later, with no explanation.
    static func importImage(from source: URL, for machineID: UUID) throws -> Imported {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let folder = try MachineDirectory.forMachine(id: machineID)
        let name = sanitized(source.lastPathComponent)
        let destination = folder.appendingPathComponent(name)
        // Replacing is deliberate: re-picking a corrected image for the same
        // name is the common case, and the media editor is per machine.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return Imported(path: destination.path,
                        format: sniffFormat(atPath: destination.path) ?? "raw")
    }

    /// Move a finished download into the machine's folder, returning its path.
    ///
    /// A move, not a copy: the file is already inside this app's container, and
    /// copying a three-gigabyte ISO would need that much free space a second time.
    static func adoptDownloaded(_ file: URL, for machineID: UUID) throws -> String {
        let folder = try MachineDirectory.forMachine(id: machineID)
        let destination = folder.appendingPathComponent(sanitized(file.lastPathComponent))
        if file.path == destination.path { return destination.path }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: file, to: destination)
        return destination.path
    }

    /// A file already in this machine's folder that the catalogue knows about.
    ///
    /// This is the path a download takes when nobody was watching. A background
    /// transfer can finish while the app is not running - that is the point of
    /// it - so there may be no view left to be told, and the file simply lands in
    /// the machine's folder. Looking for it on the next launch is what turns a
    /// finished download into an image the machine boots instead of a file the
    /// user has to hunt for in the picker.
    static func catalogImage(in folder: URL) -> Imported? {
        for image in GuestImageCatalog.images {
            let candidate = folder.appendingPathComponent(image.storedFileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return Imported(path: candidate.path, format: image.format.rawValue)
            }
        }
        return nil
    }

    /// A blank disk for an installer to write to.
    ///
    /// Sparse: a 16 GB disk costs its metadata until a guest writes into it, which
    /// matters on a phone. Truncating past the end of a file is how a sparse raw
    /// disk is made without writing 16 GB of zeroes.
    static func createInstallDisk(for machineID: UUID,
                                 gigabytes: Int = MachineImage.installDiskGigabytes) throws -> String {
        let folder = try MachineDirectory.forMachine(id: machineID)
        let target = folder.appendingPathComponent("install.raw")
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        guard fm.createFile(atPath: target.path, contents: nil) else {
            throw StorageError.cannotCreate(target.path)
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(max(1, gigabytes)) * 1024 * 1024 * 1024)
        return target.path
    }
}

/// EFI variables, written per machine.
///
/// The bundle's `edk2-arm-vars.fd` is a *template* - a few hundred kilobytes of
/// initial variables - but the `virt` machine gives its firmware a flash bank
/// the size of the code image (64 MB). A bank shorter than the device is not a
/// warning; the machine refuses to start. So the template is extended with
/// zeroes to the code image's size, once per machine.
enum WritableFirmwareVars {
    static func url(for firmware: LinuxFirmware, flashSize: Int, in folder: URL) -> URL? {
        guard let template = firmware.vars else { return nil }
        let target = folder.appendingPathComponent("efi-vars.fd")
        if let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber,
           size.intValue >= flashSize {
            return target
        }
        guard let data = try? Data(contentsOf: template) else { return nil }
        guard FileManager.default.createFile(atPath: target.path, contents: data) else { return nil }
        guard let handle = try? FileHandle(forWritingTo: target) else { return nil }
        defer { try? handle.close() }
        try? handle.truncate(atOffset: UInt64(flashSize))
        return target
    }

    /// The size the writable bank must be: the code image's own size.
    static func flashSize(for firmware: LinuxFirmware) -> Int {
        let size = (try? FileManager.default.attributesOfItem(atPath: firmware.code.path)[.size] as? NSNumber)?.intValue
        return (size ?? 0) > 0 ? size! : 64 * 1024 * 1024
    }
}

/// Reads the serial console socket, waiting for QEMU to create it.
///
/// The guest's boot log does *not* come from the engine's stdout: QEMU routes
/// `-serial` to the chardev socket, so this is the only place a boot is visible.
/// QEMU creates that socket as it starts, so the first connects legitimately fail
/// and are retried rather than reported.
final class ConsoleReader {
    private let path: String
    private let onText: (String) -> Void
    private var thread: Thread?
    private var stopped = false

    init(path: String, onText: @escaping (String) -> Void) {
        self.path = path
        self.onText = onText
    }

    func start() {
        let t = Thread { [weak self] in self?.loop() }
        t.name = "qemu-console"
        t.qualityOfService = .utility
        thread = t
        t.start()
    }

    func stop() { stopped = true }

    private func loop() {
        var fd: Int32 = -1
        // About ten seconds of patience. Giving up is not an error - the machine
        // still runs - so it is said plainly and the thread ends.
        for _ in 0..<100 where fd < 0 {
            if stopped { return }
            fd = UnixSocket.connect(path: path)
            if fd < 0 { Thread.sleep(forTimeInterval: 0.1) }
        }
        guard fd >= 0 else {
            onText("\n(console socket never appeared; the machine is running without a console view)\n")
            return
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !stopped {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            if let text = String(bytes: buffer[0..<n], encoding: .utf8) { onText(text) }
        }
        close(fd)
    }
}

/// A client for the engine's monitor socket. `quit` on it is QEMU's own
/// documented way to shut a machine down, which is the only safe way to stop.
final class MonitorWriter {
    private let path: String
    private var fd: Int32 = -1

    init(path: String) { self.path = path }

    func send(_ line: String) {
        if fd < 0 { fd = UnixSocket.connect(path: path) }
        guard fd >= 0 else { return }
        var bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeMutableBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }
}

enum UnixSocket {
    /// Connect to a Unix-domain socket, or return -1.
    static func connect(path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return -1 }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
                for (i, byte) in bytes.enumerated() { destination[i] = CChar(bitPattern: byte) }
                destination[bytes.count] = 0
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        if result != 0 { close(fd); return -1 }
        return fd
    }
}

/// QEMU writes a problem to stderr and calls `exit(1)`. In a process that embeds
/// it, that is the app vanishing with the reason lost, so its output is captured
/// into the console and appended to `Documents/linux-engine.log`.
///
/// App/EngineExitGuard.c is the other half of this: it keeps the app alive when
/// that exit happens, so the capture below has somewhere to be read.
final class EngineOutputCapture {
    private let onText: (String) -> Void
    private var readFD: Int32 = -1
    private var savedOut: Int32 = -1
    private var savedErr: Int32 = -1
    private var thread: Thread?
    private var stopped = false

    static var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("linux-engine.log")
    }

    init(onText: @escaping (String) -> Void) { self.onText = onText }

    static func note(_ line: String) {
        let text = line.hasSuffix("\n") ? line : line + "\n"
        guard let data = text.data(using: .utf8) else { return }
        let url = logURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    func attach(header: String) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return }
        readFD = fds[0]
        savedOut = dup(STDOUT_FILENO)
        savedErr = dup(STDERR_FILENO)
        dup2(fds[1], STDOUT_FILENO)
        dup2(fds[1], STDERR_FILENO)
        close(fds[1])
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)
        Self.note("--- engine start ---")
        Self.note("$ " + header)
        let t = Thread { [weak self] in self?.loop() }
        t.name = "qemu-output"
        t.qualityOfService = .utility
        thread = t
        t.start()
    }

    func detach() {
        stopped = true
        fflush(stdout); fflush(stderr)
        if savedOut >= 0 { dup2(savedOut, STDOUT_FILENO); close(savedOut); savedOut = -1 }
        if savedErr >= 0 { dup2(savedErr, STDERR_FILENO); close(savedErr); savedErr = -1 }
        if readFD >= 0 { close(readFD); readFD = -1 }
    }

    private func loop() {
        let fd = readFD
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !stopped {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            guard let text = String(bytes: buffer[0..<n], encoding: .utf8) else { continue }
            Self.note(text)
            onText(text)
        }
    }
}

/// Starts and stops one machine, and carries its console.
@MainActor
final class MachineRuntime: ObservableObject {
    static let shared = MachineRuntime()

    enum State: Equatable {
        case idle
        case running
        case stopped
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var console = ""
    @Published private(set) var runningMachine: UUID?

    private var thread: Thread?
    private var monitor: MonitorWriter?
    private var capture: EngineOutputCapture?
    private var reader: ConsoleReader?
    private let consoleLimit = 200_000

    private init() {}

    /// Start a machine. Throws with a sentence rather than crashing the app.
    func start(_ machine: Machine) throws {
        guard !state.isRunning else { throw RuntimeError.busy }
        if let blocker = LinuxBootCheck.blocker(for: machine) {
            state = .failed(blocker)
            throw RuntimeError.blocked(blocker)
        }
        guard let enginePath = LinuxBootCheck.engineURL(),
              let firmware = LinuxBootCheck.firmware(),
              let share = LinuxBootCheck.shareDirectory,
              let image = machine.imagePath else {
            let message = "The engine or its firmware is missing from this build."
            state = .failed(message)
            throw RuntimeError.blocked(message)
        }

        let engine = try QEMUEngine.load(at: enginePath)
        let folder = try MachineDirectory.forMachine(id: machine.id)
        let monitorPath = try MachineDirectory.monitorSocket(id: machine.id)
        let consolePath = try MachineDirectory.consoleSocket(id: machine.id)
        for path in [monitorPath, consolePath] { try? FileManager.default.removeItem(atPath: path) }

        let vars = WritableFirmwareVars.url(
            for: firmware,
            flashSize: WritableFirmwareVars.flashSize(for: firmware),
            in: folder)

        let format = MachineImage.format(atPath: image, recorded: machine.imageFormat)
        var installDisk = machine.diskPath
        if let path = installDisk, !FileManager.default.fileExists(atPath: path) { installDisk = nil }

        let argv = QEMUArguments.build(
            machine: machine, imagePath: image, firmware: firmware, writableVars: vars,
            shareDirectory: share, monitorPath: monitorPath, consolePath: consolePath,
            imageFormat: format, installDiskPath: installDisk)

        console = ""
        state = .running
        runningMachine = machine.id

        let summary = capabilitySummary(for: machine, format: format, installDisk: installDisk)
        append(summary)
        EngineOutputCapture.note(summary)
        for warning in LinuxBootCheck.warnings(for: machine) {
            append("note: \(warning)\n")
            EngineOutputCapture.note("note: " + warning)
        }
        append("\nstarting \(machine.name)\n$ " + argv.joined(separator: " ") + "\n\n")

        // The guest's console is a socket QEMU serves, so it does not exist
        // until QEMU is up; the reader waits for it in the background.
        monitor = MonitorWriter(path: monitorPath)
        let reader = ConsoleReader(path: consolePath) { [weak self] text in
            Task { @MainActor in self?.append(text) }
        }
        reader.start()
        self.reader = reader

        // The engine's *own* output is separate from the guest's: QEMU reports a
        // command line it cannot use by printing and calling exit(1), and a print
        // nobody reads is how the app vanishes with the reason lost. Attached
        // before the thread starts, so nothing written during init is missed.
        let capture = EngineOutputCapture { [weak self] text in
            Task { @MainActor in self?.append(text) }
        }
        capture.attach(header: argv.joined(separator: " "))
        self.capture = capture

        let thread = Thread { [weak self] in
            // Armed on this thread, immediately before the engine starts: the
            // guard has to know which thread the engine runs on, and QEMU's own
            // failure path is exit(1) (App/EngineExitGuard.c).
            EngineExitGuard.arm()
            engine.run(argv: argv)
            EngineExitGuard.disarm()
            let noted = EngineExitNote.take()
            Task { @MainActor in self?.finish(status: noted) }
        }
        thread.name = "qemu"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    /// Ask QEMU's own monitor to quit, so it flushes the guest's disk itself.
    func stop() {
        guard state.isRunning else { return }
        append("\nstop requested\n")
        monitor?.send("quit")
    }

    /// The engine called `exit` on its own thread. The guard kept the app alive;
    /// this turns that into something readable.
    func engineExitedByItself(status: Int32) {
        finish(status: status)
    }

    /// The one place an engine's end is handled, whichever way it ended.
    private func finish(status: Int32?) {
        let wasRunning = state.isRunning
        tearDown()
        runningMachine = nil
        guard wasRunning else { return }

        switch status {
        case .some(0):
            append("\nthe engine exited normally.\n")
            state = .stopped
        case .some(let code):
            append("\nthe engine stopped itself with exit(\(code)). The app is still running so this can be read; QEMU's own words are above and in Documents/linux-engine.log.\n")
            state = .failed("The engine refused to start (exit \(code)). Its own words are in the console.")
        case .none:
            append("\nengine exited\n")
            state = .stopped
        }
    }

    private func tearDown() {
        reader?.stop()
        reader = nil
        capture?.detach()
        capture = nil
        monitor = nil
    }

    /// What the app knows about itself, said in the console at every start, so
    /// that a failure is read with the facts in front of it rather than guessed
    /// at afterwards.
    private func capabilitySummary(for machine: Machine, format: String, installDisk: String?) -> String {
        let probes = JITProbes.read()
        let status = JITDetector.status(for: probes)
        var lines = ["--- this build ---"]
        lines.append("engine: \(LinuxBootCheck.engineURL()?.lastPathComponent ?? "missing")")
        lines.append("firmware: \(LinuxBootCheck.firmware()?.code.lastPathComponent ?? "missing")")
        lines.append("executable memory: \(status.isOn ? "allowed" : "refused")" + (probes.debuggerAttached ? " (debugger attached)" : " (no debugger)"))
        lines.append("guest: \(machine.guest.title), \(machine.memoryMB) MB, \(machine.cpuCount) CPU")
        lines.append("medium: \(format)" + (installDisk == nil ? ", no install disk" : ", install disk set"))
        return lines.joined(separator: "\n") + "\n"
    }

    private func append(_ text: String) {
        console += text
        if console.utf8.count > consoleLimit {
            console = "...earlier output discarded...\n" + String(console.suffix(consoleLimit / 2))
        }
    }

    enum RuntimeError: LocalizedError {
        case busy
        case blocked(String)

        var errorDescription: String? {
            switch self {
            case .busy: return "A machine is already running. Stop it first."
            case .blocked(let why): return why
            }
        }
    }
}
