import Foundation
import Darwin

/// Where one machine's own files live: its disk image, its EFI variables, and
/// the two sockets the engine is driven through.
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
        return directory
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
/// into the console and appended to Documents/linux-engine.log.
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

/// Starts and stops one Linux machine, and carries its console.
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
    private let consoleLimit = 200_000

    private init() {}

    /// Start a machine. Throws with a sentence rather than crashing the app.
    func start(_ machine: Machine) throws {
        guard !state.isRunning else { throw RuntimeError.busy }
        if let blocker = LinuxBootCheck.blocker(imagePath: machine.imagePath) {
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
        let monitorPath = folder.appendingPathComponent("monitor.sock").path
        let consolePath = folder.appendingPathComponent("console.sock").path
        for path in [monitorPath, consolePath] { try? FileManager.default.removeItem(atPath: path) }

        let vars = WritableFirmwareVars.url(
            for: firmware,
            flashSize: WritableFirmwareVars.flashSize(for: firmware),
            in: folder)

        let argv = QEMUArguments.build(
            machine: machine, imagePath: image, firmware: firmware, writableVars: vars,
            shareDirectory: share, monitorPath: monitorPath, consolePath: consolePath)

        console = ""
        state = .running
        runningMachine = machine.id
        append("starting \(machine.name)\n$ " + argv.joined(separator: " ") + "\n\n")

        monitor = MonitorWriter(path: monitorPath)
        let capture = EngineOutputCapture { [weak self] text in
            Task { @MainActor in self?.append(text) }
        }
        capture.attach(header: argv.joined(separator: " "))
        self.capture = capture

        let thread = Thread { [weak self] in
            engine.run(argv: argv)
            Task { @MainActor in self?.exited() }
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

    private func exited() {
        append("\nengine exited\n")
        capture?.detach()
        capture = nil
        monitor = nil
        runningMachine = nil
        state = .stopped
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