import Foundation
import Darwin

/// What this process can actually do, measured rather than assumed.
///
/// This exists because "the app vanished when I pressed Start" has three
/// different causes that look identical from the outside: the engine called
/// `exit` on a command line it would not take (App/EngineExitGuard.c), the system
/// killed the app for holding a guest's RAM, or - if a JIT-capable engine is ever
/// shipped - iOS refused it executable memory. Only the first can be reported
/// after the fact; the other two have to be known before Start is pressed, which
/// is what the probes here are for.
enum JITStatus: Equatable {
    case on
    case off(JITOffReason)

    var isOn: Bool { self == .on }

    var headline: String {
        switch self {
        case .on: return "Executable memory: allowed"
        case .off: return "Executable memory: refused"
        }
    }

    var symbol: String { self == .on ? "bolt.fill" : "bolt.slash.fill" }

    var detail: String {
        switch self {
        case .on:
            return "This process may create executable memory, so a JIT is not the thing standing between you and a guest. The engine in this build interprets guest code, so this changes nothing about how fast it runs today; it matters when a JIT-capable engine is shipped."
        case .off(let reason):
            return reason.explanation
        }
    }
}

/// Why executable memory is not available, in words a person can act on.
enum JITOffReason: Equatable {
    /// No debugger is attached, or the build was not signed to allow one.
    case debuggerNotAttached
    /// A debugger is attached and the mapping was refused anyway.
    case executableMemoryRefused

    var explanation: String {
        switch self {
        case .debuggerNotAttached:
            return "iOS only hands a process executable memory while a debugger holds it attached, and only a build signed with get-task-allow and com.apple.security.cs.allow-jit can be debugged. A sideloader that strips entitlements cannot grant it. The engine in this build interprets guest code, so a machine still runs without this."
        case .executableMemoryRefused:
            return "A debugger is attached, but a MAP_JIT page could not be mapped. That usually means the build was signed without com.apple.security.cs.allow-jit, or the Developer Disk Image no longer matches this iOS version."
        }
    }
}

/// The measurements the decision is made from, kept separate so the decision
/// itself can be tested without a device.
struct JITProbes: Equatable {
    /// A debugger is attached to this process (`P_TRACED`).
    var debuggerAttached: Bool
    /// A `MAP_JIT` page could be mapped and marked executable.
    var executableMemoryAvailable: Bool

    static func read() -> JITProbes {
        JITProbes(debuggerAttached: JITDetector.isDebuggerAttached(),
                  executableMemoryAvailable: JITDetector.canMapExecutableMemory())
    }

    static let none = JITProbes(debuggerAttached: false, executableMemoryAvailable: false)
}

/// The two probes, and the rule that reads them.
enum JITDetector {
    /// The mapping is the decisive probe; a debugger alone can be attached and
    /// still be granted nothing.
    static func status(for probes: JITProbes) -> JITStatus {
        if probes.executableMemoryAvailable { return .on }
        return .off(probes.debuggerAttached ? .executableMemoryRefused : .debuggerNotAttached)
    }

    /// Is a debugger attached to this process?
    ///
    /// `P_TRACED` on our own `kinfo_proc`, which is the flag a debugger sets when
    /// it attaches and the same one iOS consults before allowing a JIT.
    static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = name.withUnsafeMutableBufferPointer { mib -> Int32 in
            sysctl(mib.baseAddress, UInt32(mib.count), &info, &size, nil, 0)
        }
        guard result == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// Can this process map executable memory?
    ///
    /// One page, `PROT_READ | PROT_WRITE | PROT_EXEC` with `MAP_JIT`, then
    /// dropped to `PROT_READ | PROT_EXEC`. The second step is checked because a
    /// mapping can succeed and the protection change be refused, and it is the
    /// protection change a translator actually needs.
    ///
    /// The page is never executed: calling into it would crash the app on a build
    /// whose entitlements are missing, which is exactly the build that would run
    /// this probe. Mapping and protecting is enough to know.
    static func canMapExecutableMemory() -> Bool {
        let size = Int(getpagesize())
        let raw = mmap(nil, size, PROT_READ | PROT_WRITE | PROT_EXEC,
                       MAP_PRIVATE | MAP_ANON | JITDetector.mapJIT, -1, 0)
        guard let base = raw, base != UnsafeMutableRawPointer(bitPattern: -1) else { return false }
        let protected = mprotect(base, size, PROT_READ | PROT_EXEC)
        munmap(base, size)
        return protected == 0
    }

    /// Darwin's MAP_JIT. Spelled out as a number because Swift's copy of
    /// <sys/mman.h> does not always carry it, and a wrong flag here would report
    /// "refused" on a build that is fine.
    static let mapJIT: Int32 = 0x0800
}

/// What the diagnostics screen shows, assembled from measurements only.
struct CapabilityRow: Equatable {
    let title: String
    let value: String
    let detail: String?
    /// Something the user can act on, coloured accordingly.
    let isWarning: Bool
}

/// The rows, built by a pure function so the wording and the warnings are
/// covered by tests rather than only by whoever reads them on a device.
enum CapabilityReport {
    /// Guest RAM above this is where an app without the increased-memory-limit
    /// entitlement starts being at risk: a guest's RAM is one allocation in this
    /// process, and the ordinary per-app limit on a current iPhone is well under
    /// a couple of gigabytes.
    static let unentitledGuestLimitMB = 1024

    /// The message to show for a machine asking for `guestMegabytes`, or nil when
    /// there is nothing to say.
    static func memoryWarning(guestMegabytes: Int, physicalMemory: UInt64) -> String? {
        guard guestMegabytes > unentitledGuestLimitMB else { return nil }
        let device = ByteCountFormatter.string(fromByteCount: Int64(physicalMemory), countStyle: .memory)
        return "This machine asks for \(guestMegabytes) MB of guest RAM, and this device has \(device) of memory in total. The guest's RAM is one allocation inside this app, so unless the build was signed with com.apple.developer.kernel.increased-memory-limit, iOS can kill the app the moment it allocates - the screen goes away with no message. 1024 MB or less is what runs without that entitlement."
    }

    static func rows(probes: JITProbes,
                     engine: EngineStatus,
                     firmware: LinuxFirmware?,
                     physicalMemory: UInt64,
                     guestMegabytes: Int?) -> [CapabilityRow] {
        let status = JITDetector.status(for: probes)
        var rows: [CapabilityRow] = []

        rows.append(CapabilityRow(
            title: "Engine",
            value: engine.briefDescription,
            detail: engine == .missing
                ? "This build was packaged without Frameworks/qemu-aarch64-softmmu.framework, so no machine can start. Use an IPA from a green run."
                : nil,
            isWarning: engine == .missing))

        rows.append(CapabilityRow(
            title: "UEFI firmware",
            value: firmware == nil ? "missing" : "edk2-aarch64, present",
            detail: firmware == nil
                ? "share/qemu/edk2-aarch64-code.fd is not in this bundle, so a machine has no firmware to boot."
                : nil,
            isWarning: firmware == nil))

        rows.append(CapabilityRow(
            title: status.headline,
            value: status.isOn ? "yes" : "no",
            detail: status.detail + (probes.debuggerAttached
                                     ? " A debugger is attached, which is what lets iOS consider it."
                                     : " No debugger is attached."),
            isWarning: !status.isOn))

        rows.append(CapabilityRow(
            title: "Engine kind",
            value: "TCG interpreter",
            detail: "This build's QEMU interprets guest code instead of compiling it, which is why it runs without a JIT entitlement. It is also why a boot is slow: an ISO's installer can take minutes to reach its first screen.",
            isWarning: false))

        if let guestMegabytes {
            let warning = memoryWarning(guestMegabytes: guestMegabytes, physicalMemory: physicalMemory)
            rows.append(CapabilityRow(
                title: "Guest memory",
                value: "\(guestMegabytes) MB",
                detail: warning ?? "Within what an unentitled app is normally allowed to hold.",
                isWarning: warning != nil))
        }

        if let exitNote = EngineExitNote.peek() {
            rows.append(CapabilityRow(
                title: "Last engine exit",
                value: "exit(\(exitNote))",
                detail: "The engine gave up by itself; QEMU's own words are in the console and in Documents/linux-engine.log.",
                isWarning: true))
        }

        return rows
    }
}

extension EngineStatus {
    /// A one-word description for the diagnostics screen.
    var briefDescription: String {
        switch self {
        case .available: return "present"
        case .missing: return "missing"
        }
    }
}
