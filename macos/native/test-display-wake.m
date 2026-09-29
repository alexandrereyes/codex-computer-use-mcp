#import "DisplayWake.h"
#include <assert.h>
#include <sys/socket.h>
#include <unistd.h>

// Power APIs and clock are replaced at link/compile time. Never wake a real display.
static double clockValue, visibleAt;
static BOOL active, changeSession, unknownLock, signedLogin, failCreate, failWake, cancelDuringWait;
static unsigned creates, wakes, activityReleases, displayReleases;
static int peer;
BOOL MLGraphicalSessionActive(void) { return active; }
MLLockState MLScreenLockState(void) { return unknownLock ? MLLockUnknown : MLLockLocked; }
pid_t MLLoginPID(void) { return signedLogin ? 614 : -1; }
BOOL MLLoginUIShown(void) { return clockValue >= visibleAt; }
double MLMonotonicTime(void) { return clockValue; }
int fixture_sleep(useconds_t micros) {
    clockValue += micros / 1e6;
    if (changeSession) active = NO;
    if (cancelDuringWait) { assert(write(peer, "STOP\n", 5) == 5); cancelDuringWait = NO; }
    return 0;
}
IOReturn fixture_create(CFStringRef type, IOPMAssertionLevel level, CFStringRef name, IOPMAssertionID *out) {
    assert(CFEqual(type, kIOPMAssertionTypePreventUserIdleDisplaySleep) && level == kIOPMAssertionLevelOn && name);
    ++creates;
    if (failCreate) return kIOReturnError;
    *out = 101; return kIOReturnSuccess;
}
IOReturn fixture_activity(CFStringRef name, IOPMUserActiveType type, IOPMAssertionID *out) {
    assert(name && type == kIOPMUserActiveLocal); ++wakes;
    if (failWake) return kIOReturnError;
    *out = 202; return kIOReturnSuccess;
}
IOReturn fixture_release(IOPMAssertionID assertion) {
    if (assertion == 101) { assert(displayReleases++ == 0); }
    else { assert(assertion == 202 && activityReleases++ == 0); }
    return kIOReturnSuccess;
}
int main(void) {
    @autoreleasepool {
        for (unsigned scenario = 0; scenario < 8; ++scenario) {
            clockValue = 0; visibleAt = scenario == 1 ? 0 : (scenario == 2 ? 10 : 0.15);
            active = YES; signedLogin = scenario != 4; unknownLock = scenario == 3;
            changeSession = scenario == 5; failCreate = scenario == 6; failWake = scenario == 7;
            cancelDuringWait = NO; creates = wakes = activityReleases = displayReleases = 0;
            int pair[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0); peer = pair[1];
            IOPMAssertionID display;
            NSString *failure = MLPrepareLockedDisplay(pair[0], &display);
            if (scenario <= 1) {
                assert(!failure && display == 101 && displayReleases == 0);
                assert(wakes == (scenario == 0 ? 1u : 0u));
                assert(activityReleases == wakes); // Wake assertion released, display hold retained through the lease.
                MLReleaseDisplay(&display); MLReleaseDisplay(&display);
                assert(displayReleases == 1 && display == kIOPMNullAssertionID);
            } else {
                assert(failure && display == kIOPMNullAssertionID);
                assert(displayReleases == (creates && !failCreate ? 1u : 0u));
                assert(activityReleases == (wakes && !failWake ? 1u : 0u));
                if (scenario == 2) assert([failure isEqual:@"display-wake-login-ui-timeout"] && clockValue >= 3 && clockValue < 3.1);
                if (scenario == 3 || scenario == 4) assert(creates == 0 && wakes == 0);
            }
            close(pair[0]); close(pair[1]);
        }
        // Existing control channel cancels readiness; no extra socket or synthetic input.
        for (unsigned eof = 0; eof < 2; ++eof) {
            clockValue = 0; visibleAt = 10; active = signedLogin = YES;
            changeSession = unknownLock = failCreate = failWake = NO;
            creates = wakes = activityReleases = displayReleases = 0;
            cancelDuringWait = !eof;
            int pair[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0); peer = pair[1];
            if (eof) shutdown(peer, SHUT_WR);
            IOPMAssertionID display;
            assert(MLPrepareLockedDisplay(pair[0], &display) && display == kIOPMNullAssertionID);
            assert(creates == (eof ? 0u : 1u) && displayReleases == creates && activityReleases == wakes);
            close(pair[0]); close(pair[1]);
        }
        puts("PASS: display-off -> confirmed locked UI; already visible; bounded timeout; session/unknown/signature/API failures; cancel/EOF release assertions. Mock power only, no auth/input/GUI.");
        return 0;
    }
}
