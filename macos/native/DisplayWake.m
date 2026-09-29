#import "DisplayWake.h"
#include <sys/socket.h>
#include <errno.h>
#include <unistd.h>

static BOOL cancelled(int fd) {
    char byte;
    ssize_t count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT);
    return count >= 0 || (errno != EAGAIN && errno != EWOULDBLOCK);
}
static BOOL lockedSession(void) {
    return MLGraphicalSessionActive() && MLScreenLockState() == MLLockLocked && MLLoginPID() > 1;
}
void MLReleaseDisplay(IOPMAssertionID *assertion) {
    if (*assertion == kIOPMNullAssertionID) return;
    IOReturn status = IOPMAssertionRelease(*assertion);
    *assertion = kIOPMNullAssertionID;
    fprintf(stderr, "DISPLAY_WAKE_END releaseStatus=%d\n", status);
}
NSString *MLPrepareLockedDisplay(int fd, IOPMAssertionID *display) {
    *display = kIOPMNullAssertionID;
    if (cancelled(fd) || !lockedSession()) return @"display-wake-session-or-channel-invalid";
    // This assertion prevents idle display sleep; it does not wake an already-off display.
    if (IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep,
        kIOPMAssertionLevelOn, CFSTR("MacLock protected Computer Use"), display) != kIOReturnSuccess)
        return @"display-hold-failed";
    IOPMAssertionID activity = kIOPMNullAssertionID;
    NSString *failure = nil;
    double deadline = MLMonotonicTime() + 3;
    if (!MLLoginUIShown()) {
        fprintf(stderr, "DISPLAY_WAKE_REQUEST locked=1 loginUI=0\n");
        // Local selects visible display activity, not remote GPU-only use. No HID/auth event.
        if (IOPMAssertionDeclareUserActivity(CFSTR("MacLock show locked login UI"),
            kIOPMUserActiveLocal, &activity) != kIOReturnSuccess) failure = @"display-wake-request-failed";
    }
    while (!failure) {
        if (cancelled(fd) || !lockedSession()) { failure = @"display-wake-session-or-channel-invalid"; break; }
        if (MLMonotonicTime() >= deadline) { failure = @"display-wake-login-ui-timeout"; break; }
        if (MLLoginUIShown()) break; // Request success alone never authorizes guard setup or Allow.
        usleep(50000);
    }
    if (activity != kIOPMNullAssertionID) IOPMAssertionRelease(activity);
    if (failure) MLReleaseDisplay(display);
    else fprintf(stderr, "DISPLAY_WAKE_READY locked=1 loginUI=1 held=1\n");
    return failure;
}
