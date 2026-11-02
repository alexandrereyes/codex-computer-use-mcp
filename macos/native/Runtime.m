#import "Runtime.h"
#import <AppKit/AppKit.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <dlfcn.h>
#include <time.h>
#include <notify.h>

NSString *const MLInstallRoot = @"/Library/Application Support/MacLock";
NSString *const MLExecutable = @"/Library/Application Support/MacLock/MacLock.app/Contents/MacOS/mac-lock";
NSString *const MLRight = @"br.com.alexandrem.mac-lock.operation";
double MLMonotonicTime(void) {
    struct timespec value; clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1e9;
}

NSDictionary *MLReadConfig(void) {
    NSString *path = [MLInstallRoot stringByAppendingPathComponent:@"config.plist"];
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) || !S_ISREG(st.st_mode) || st.st_uid != 0 || (st.st_mode & 022)) return nil;
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfURL:[NSURL fileURLWithPath:path] error:NULL];
    if (![config[@"uid"] isKindOfClass:NSNumber.class] || ![config[@"controllerRequirement"] isKindOfClass:NSString.class]) return nil;
    return config;
}
MLLockState MLSessionLockState(NSDictionary *session) {
    if (!session) return MLLockUnknown;
    // This macOS omits the flag when unlocked; an unavailable session is different.
    id flag = session[@"CGSSessionScreenIsLocked"];
    if (!flag || [flag isEqual:@NO]) return MLLockUnlocked;
    return [flag isEqual:@YES] ? MLLockLocked : MLLockUnknown;
}
BOOL MLInstallationEnabled(NSDictionary *config, NSTimeInterval now) {
    return ![config[@"disabled"] isEqual:@YES] &&
        ([config[@"persistent"] isEqual:@YES] || [config[@"experimentalUntil"] doubleValue] > now);
}
BOOL MLSuppressionSpent(BOOL leaseActive, BOOL unlocked, double markerTime, double bootTime) {
    if (leaseActive) return NO;
    return unlocked || (markerTime > 0 && bootTime > 0 && markerTime < bootTime);
}
MLLockState MLScreenLockState(void) {
    return MLSessionLockState(CFBridgingRelease(CGSessionCopyCurrentDictionary()));
}
BOOL MLLoginUIShown(void) {
    // loginwindow publishes this state when its secure UI is shown/hidden.
    // Unlike window ordering, it does not assume a particular compositor layout.
    int token;
    if (notify_register_check("com.apple.sessionagent.screenLockUIIsShowing", &token) != NOTIFY_STATUS_OK) return NO;
    uint64_t state = 0;
    uint32_t status = notify_get_state(token, &state);
    notify_cancel(token);
    return status == NOTIFY_STATUS_OK && state == 1;
}
BOOL MLCoverageQualified(MLLockState state, BOOL loginVisible, BOOL overlayVisible) {
    return (state == MLLockLocked || state == MLLockUnlocked) &&
        (overlayVisible || (state == MLLockLocked && loginVisible));
}
MLCoverageObservation MLObserveCoverage(MLLockState state, BOOL loginVisible, BOOL overlayVisible, BOOL possibleGrant, BOOL previouslyVisible) {
    if (state == MLLockUnknown) return MLCoverageFailed;
    if (MLCoverageQualified(state, loginVisible, overlayVisible))
        return state == MLLockUnlocked ? MLCoverageVisible : MLCoveragePrepared;
    return possibleGrant && !previouslyVisible ? MLCoveragePending : MLCoverageFailed;
}
BOOL MLGraphicalSessionActive(void) {
    NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    return [session[(__bridge NSString *)kCGSessionOnConsoleKey] isEqual:@YES] &&
        [session[(__bridge NSString *)kCGSessionLoginDoneKey] isEqual:@YES] &&
        [session[(__bridge NSString *)kCGSessionUserIDKey] unsignedIntValue] == getuid();
}
static SecCodeRef copyCode(pid_t pid) {
    SecCodeRef code = NULL;
    NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributePid: @(pid)};
    SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &code);
    return code;
}
BOOL MLCodeMatches(pid_t pid, NSString *text) {
    SecCodeRef code = copyCode(pid);
    SecRequirementRef requirement = NULL;
    BOOL valid = NO;
    if (code && SecRequirementCreateWithString((__bridge CFStringRef)text, kSecCSDefaultFlags, &requirement) == errSecSuccess)
        valid = SecCodeCheckValidity(code, kSecCSStrictValidate, requirement) == errSecSuccess;
    if (requirement) CFRelease(requirement);
    if (code) CFRelease(code);
    return valid;
}
pid_t MLLoginPID(void) {
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications)
        if ([app.bundleIdentifier isEqual:@"com.apple.loginwindow"] &&
            MLCodeMatches(app.processIdentifier, @"identifier \"com.apple.loginwindow\" and anchor apple")) return app.processIdentifier;
    return -1;
}
BOOL MLPeerMatches(int fd, SecRequirementRef requirement) {
    audit_token_t token;
    socklen_t size = sizeof(token);
    if (!requirement || getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) || size != sizeof(token)) return NO;
    NSData *data = [NSData dataWithBytes:&token length:sizeof(token)];
    NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributeAudit: data};
    SecCodeRef code = NULL;
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &code);
    if (status == errSecSuccess) status = SecCodeCheckValidity(code, kSecCSStrictValidate, requirement);
    if (code) CFRelease(code);
    return status == errSecSuccess;
}
SecRequirementRef MLCopyNativeRequirement(void) {
    struct stat st;
    if (lstat(MLExecutable.fileSystemRepresentation, &st) || !S_ISREG(st.st_mode) || st.st_uid != 0 || (st.st_mode & 022)) return NULL;
    SecStaticCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    if (SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:MLExecutable], kSecCSDefaultFlags, &code) == errSecSuccess &&
        SecStaticCodeCheckValidity(code, kSecCSStrictValidate, NULL) == errSecSuccess)
        SecCodeCopyDesignatedRequirement(code, kSecCSDefaultFlags, &requirement);
    if (code) CFRelease(code);
    return requirement;
}
static BOOL addressFor(NSString *path, struct sockaddr_un *address) {
    memset(address, 0, sizeof(*address)); address->sun_family = AF_UNIX;
    const char *p = path.fileSystemRepresentation;
    if (strlen(p) >= sizeof(address->sun_path)) return NO;
    strlcpy(address->sun_path, p, sizeof(address->sun_path)); return YES;
}
static int streamSocket(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return fd;
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    struct timeval timeout = {.tv_sec = 2};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    return fd;
}
int MLConnect(NSString *path) {
    struct sockaddr_un address;
    if (!addressFor(path, &address)) return -1;
    int fd = streamSocket();
    if (fd < 0) return fd;
    int flags = fcntl(fd, F_GETFL);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address))) {
        if (errno != EINPROGRESS) { int error = errno; close(fd); errno = error; return -1; }
        struct pollfd waiter = {.fd = fd, .events = POLLOUT};
        int error = 0; socklen_t size = sizeof(error);
        if (poll(&waiter, 1, 2000) <= 0 || getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) || error) {
            close(fd); errno = error ? error : ETIMEDOUT; return -1;
        }
    }
    fcntl(fd, F_SETFL, flags);
    return fd;
}
int MLListen(NSString *path, mode_t mode) {
    struct sockaddr_un address;
    if (!addressFor(path, &address)) return -1;
    struct stat st;
    if (!lstat(path.fileSystemRepresentation, &st)) {
        if (!S_ISSOCK(st.st_mode) || st.st_uid != getuid()) return -1;
        int live = MLConnect(path);
        if (live >= 0) { close(live); return -1; }
        if (errno != ECONNREFUSED) return -1;
        if (unlink(path.fileSystemRepresentation)) return -1;
    }
    int fd = streamSocket();
    if (fd >= 0 && (bind(fd, (struct sockaddr *)&address, sizeof(address)) || chmod(path.fileSystemRepresentation, mode) || listen(fd, 8))) {
        close(fd); return -1;
    }
    return fd;
}
NSString *MLReadLine(int fd) {
    char buffer[128]; size_t used = 0;
    while (used < sizeof(buffer) - 1) {
        char c;
        if (read(fd, &c, 1) != 1) return nil;
        if (c == '\n') { buffer[used] = 0; return [NSString stringWithUTF8String:buffer]; }
        buffer[used++] = c;
    }
    return nil;
}
BOOL MLWriteLine(int fd, NSString *line) {
    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    const char *p = data.bytes; size_t left = data.length;
    while (left) { ssize_t n = write(fd, p, left); if (n <= 0) return NO; p += n; left -= (size_t)n; }
    return YES;
}
static void key(CGEventSourceRef source, CGKeyCode code, BOOL down, CGEventFlags flags, pid_t pid) {
    CGEventRef event = CGEventCreateKeyboardEvent(source, code, down);
    if (!event) return;
    CGEventSetFlags(event, flags);
    if (pid > 0) CGEventPostToPid(pid, event); else CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}
void MLPostReturn(pid_t pid) {
    if (pid <= 1 || !MLGraphicalSessionActive()) return;
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    if (!source) return;
    key(source, 36, YES, 0, pid); key(source, 36, NO, 0, pid); CFRelease(source);
}
void MLPostLock(void) {
    if (!MLGraphicalSessionActive()) return;
    // Present in the probed macOS 27 login.framework. This requests a real system
    // lock without relying on event-posting permission. Never treat its return as confirmation.
    static void (*lockImmediately)(void);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *library = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY | RTLD_LOCAL);
        if (library) lockImmediately = dlsym(library, "SACLockScreenImmediate");
    });
    if (lockImmediately) { lockImmediately(); return; }
    if (!CGPreflightPostEventAccess()) return;
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    if (!source) return;
    CGEventFlags both = kCGEventFlagMaskCommand | kCGEventFlagMaskControl;
    key(source, 55, YES, kCGEventFlagMaskCommand, 0); key(source, 59, YES, both, 0);
    key(source, 12, YES, both, 0); key(source, 12, NO, both, 0);
    key(source, 59, NO, kCGEventFlagMaskCommand, 0); key(source, 55, NO, 0, 0);
    CFRelease(source);
}
