//
//  MadeiraNext-Bridging-Header.h
//  The one C interface in the app: App/EngineExitGuard.c.
//
//  Set as SWIFT_OBJC_BRIDGING_HEADER in project.yml. Nothing else is exposed
//  here on purpose - everything else in the app is Swift.
//

#ifndef MADEIRA_NEXT_BRIDGING_HEADER_H
#define MADEIRA_NEXT_BRIDGING_HEADER_H

#include <stdint.h>

/// Arm the exit guard for the calling thread. Call on the engine's own thread,
/// just before the engine is started.
void madeira_engine_guard_arm(void);

/// Stand the guard down after the engine returns by itself.
void madeira_engine_guard_disarm(void);

/// Non-zero while the guard is armed.
int madeira_engine_guard_armed(void);

#endif /* MADEIRA_NEXT_BRIDGING_HEADER_H */
