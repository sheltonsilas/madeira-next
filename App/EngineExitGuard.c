// EngineExitGuard.c - keep the app alive when the engine calls exit().
//
// WHY THIS EXISTS
// QEMU answers a command line it cannot use by printing to stderr and calling
// exit(1) (see QEMU's qemu_init, and this app's own docs/ARCHITECTURE.md). Inside
// a process that has dlopen'ed QEMU, that exit is not QEMU stopping: it is the
// whole app terminating. The user sees the app vanish the instant they press
// Start, and the line QEMU printed goes with it - the log is flushed as part of
// the same exit, and whether it survives depends on luck.
//
// WHAT IT DOES INSTEAD
// The replacement below is installed with DYLD_INTERPOSE, which rewrites the
// process's symbol table so every image that refers to `exit` - including the
// engine framework, whose reference is resolved when it is dlopen'ed - arrives
// here first. If the caller is the thread the engine is running on, the exit is
// recorded and that thread is ended with pthread_exit, which leaves the rest of
// the app alive to say what happened. Anything else owns the process: it is
// flushed and exited exactly as before, so an ordinary termination is unchanged.
//
// WHAT IT CANNOT CATCH
// A crash (SIGSEGV, SIGILL) is not an exit call and is not intercepted; neither
// is the system killing the app for memory (SIGKILL, jetsam), which is the other
// way "press Start and the app disappears" happens. App/JITStatus.swift and the
// diagnostics screen exist for that one.
//
// This is the only C in the app. It is not because the guard is subtle; it is
// because interposition is a linker-level table and Swift cannot place one.

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Implemented in Swift (App/EngineExitGuard.swift) with @_cdecl. It must be safe
// to call from the engine's thread: it records the status, writes it to the
// engine log, and hands it to the main queue.
extern void madeira_engine_noted_exit(int32_t status);

static _Atomic(int) guard_armed = 0;
static _Atomic(uintptr_t) guard_thread = 0;

/// Arm the guard for the calling thread. Called on the engine thread itself,
/// immediately before the engine is started, so the recorded thread is the one
/// QEMU will run on.
void madeira_engine_guard_arm(void) {
    atomic_store(&guard_thread, (uintptr_t)pthread_self());
    atomic_store(&guard_armed, 1);
}

/// Stand the guard down: the engine returned on its own and the app is in
/// control of the sequence again.
void madeira_engine_guard_disarm(void) {
    atomic_store(&guard_armed, 0);
}

/// Whether the guard is currently armed, for the tests and the diagnostics row.
int madeira_engine_guard_armed(void) {
    return atomic_load(&guard_armed);
}

static void madeira_exit(int status) __attribute__((noreturn));

static void madeira_exit(int status) {
    const uintptr_t self = (uintptr_t)pthread_self();
    const uintptr_t owner = atomic_load(&guard_thread);

    if (atomic_load(&guard_armed) && self == owner) {
        // Disarm first: if anything on the way out calls exit again, it must not
        // come back here and end the process this guard exists to protect.
        atomic_store(&guard_armed, 0);
        madeira_engine_noted_exit((int32_t)status);
        // Ending this thread, not the process. The engine's own stack is
        // abandoned with it, which is correct: the engine has given up, and
        // nothing else runs on this thread.
        pthread_exit(NULL);
    }

    // Not the engine's thread. This is somebody genuinely terminating the
    // process, so do what exit does: flush, then go.
    fflush(NULL);
    _exit(status);
}

// DYLD_INTERPOSE is usually spelled out by <mach-o/dyld-interposing.h>, which is
// not in every SDK; this is the same table that header builds. `replacee` is the
// symbol every other image means when it says exit, and taking its address in
// this image resolves to the original rather than to the replacement below.
#define MADEIRA_INTERPOSE(replacement, replacee)                              \
    __attribute__((used)) static struct {                                     \
        const void *replacement;                                              \
        const void *replacee;                                                 \
    } _madeira_interpose_##replacee                                           \
        __attribute__((section("__DATA,__interpose"))) = {                    \
            (const void *)(uintptr_t)&replacement,                            \
            (const void *)(uintptr_t)&replacee,                               \
    };

MADEIRA_INTERPOSE(madeira_exit, exit)
