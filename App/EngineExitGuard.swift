import Foundation

/// Swift's side of App/EngineExitGuard.c.
///
/// The C half does the interposing and decides whether an `exit` call belongs to
/// the engine's thread. This half is what that decision is reported to.
enum EngineExitGuard {
    /// Arm the guard for the calling thread. Must be called *on* the engine's
    /// thread, immediately before the engine is started, so the recorded thread
    /// is the one QEMU will run on.
    static func arm() {
        madeira_engine_guard_arm()
    }

    /// The engine returned on its own.
    static func disarm() {
        madeira_engine_guard_disarm()
    }

    static var isArmed: Bool { madeira_engine_guard_armed() != 0 }
}

/// The status an engine-reported `exit` carried, held between the engine's
/// thread and the main queue.
///
/// A lock rather than an actor: the writer is a thread that is about to be
/// terminated with `pthread_exit`, so it cannot await anything to record one
/// integer.
enum EngineExitNote {
    private static let lock = NSLock()
    private static var pending: Int32?

    static func record(_ status: Int32) {
        lock.lock()
        pending = status
        lock.unlock()
    }

    static func take() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        let value = pending
        pending = nil
        return value
    }

    /// The last noted status without consuming it, for the diagnostics screen,
    /// which may be asked for its rows more than once.
    static func peek() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }
}

/// Called by the C interposer, on the engine's thread, when the engine called
/// `exit`. The thread is about to end, so this records what happened and hands
/// the news to the main queue; nothing else here may block.
///
/// @_cdecl rather than a Swift-visible function because the caller is C. The
/// name is the one App/EngineExitGuard.c declares.
@_cdecl("madeira_engine_noted_exit")
func madeira_engine_noted_exit(_ status: Int32) {
    EngineExitNote.record(status)
    // Written from this thread rather than handed to the main queue, because the
    // whole point is that the message survives an engine that has just given up.
    EngineOutputCapture.note("--- the engine called exit(\(status)) ---")
    EngineOutputCapture.note("A rejected command line is QEMU's usual reason for this; the lines above are its own.")
    Task { @MainActor in
        MachineRuntime.shared.engineExitedByItself(status: status)
    }
}
