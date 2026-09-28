#import "Runtime.h"
#include "Attempt.h"
#include <Security/AuthorizationPlugin.h>
#include <assert.h>
#include <sys/socket.h>
#include <unistd.h>

// Link-time test transport; never part of either installed binary. The real
// Authorization.m is exercised with an isolated engine and the real attempt core.
NSString *const MLInstallRoot = @"isolated-test";
NSString *const MLExecutable = @"isolated-test";
NSString *const MLRight = @"br.com.alexandrem.mac-lock.operation";
static MLAttempt attempt;
static int remoteFD;
static BOOL cancelAfterPermit;
static NSString *lastReport;
static NSString *requestedNonce;
static AuthorizationResult result;
NSDictionary *MLReadConfig(void) { return @{@"uid": @(getuid())}; }
SecRequirementRef MLCopyNativeRequirement(void) {
    SecRequirementRef r = NULL;
    assert(SecRequirementCreateWithString(CFSTR("identifier \"test\""), kSecCSDefaultFlags, &r) == errSecSuccess);
    return r;
}
int MLConnect(NSString *path) {
    (void)path;
    int pair[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0); remoteFD = pair[1]; return pair[0];
}
BOOL MLPeerMatches(int fd, SecRequirementRef requirement) { (void)fd; (void)requirement; return YES; }
BOOL MLWriteLine(int fd, NSString *line) {
    (void)fd;
    NSArray *parts = [line componentsSeparatedByString:@" "];
    if ([line hasPrefix:@"AUTHORIZE 614 "]) {
        assert(parts.count == 3); requestedNonce = parts[2];
    } else {
        assert([parts[0] isEqual:@"GRANT_SENT"] || [parts[0] isEqual:@"NO_GRANT"]);
        lastReport = parts[0];
    }
    return YES;
}
NSString *MLReadLine(int fd) {
    (void)fd; close(remoteFD);
    if (!MLConsume(&attempt, 10.77, 614, true, true)) return @"DENY";
    if (cancelAfterPermit) MLStop(&attempt); // Peer can cancel after the reply was issued.
    return [NSString stringWithFormat:@"ALLOW %u %@", getuid(), requestedNonce];
}
static OSStatus getHint(AuthorizationEngineRef engine, AuthorizationString key, const AuthorizationValue **out) {
    (void)engine;
    static int pid = 614;
    static char right[] = "system.login.screensaver";
    static AuthorizationValue value;
    value = strcmp(key, "client-pid") == 0 ? (AuthorizationValue){sizeof(pid), &pid} : (AuthorizationValue){sizeof(right), right};
    *out = &value; return errAuthorizationSuccess;
}
static OSStatus setContext(AuthorizationEngineRef engine, AuthorizationString key, AuthorizationContextFlags flags, const AuthorizationValue *value) {
    (void)engine; (void)key; (void)flags; (void)value;
    assert(!"Must not manufacture credentials or modify authorization context");
    return errAuthorizationInternal;
}
static OSStatus setResult(AuthorizationEngineRef engine, AuthorizationResult decision) {
    (void)engine;
    result = decision; return errAuthorizationSuccess;
}
int main(void) {
    @autoreleasepool {
        AuthorizationCallbacks callbacks = {.version = kAuthorizationCallbacksVersion, .GetHintValue = getHint,
            .SetContextValue = setContext, .SetResult = setResult};
        AuthorizationPluginRef plugin;
        const AuthorizationPluginInterface *api;
        assert(AuthorizationPluginCreate(&callbacks, &plugin, &api) == errAuthorizationSuccess);
        AuthorizationMechanismRef mechanism;
        assert(api->MechanismCreate(plugin, (AuthorizationEngineRef)&callbacks, "operation", &mechanism) == errAuthorizationSuccess);
        assert(MLArm(&attempt, 10, 614, true, true));
        assert(api->MechanismInvoke(mechanism) == errAuthorizationSuccess && result == kAuthorizationResultAllow);
        assert([lastReport isEqual:@"GRANT_SENT"]);
        assert(api->MechanismInvoke(mechanism) == errAuthorizationSuccess && result == kAuthorizationResultDeny);
        attempt = (MLAttempt){0}; cancelAfterPermit = YES;
        assert(MLArm(&attempt, 10, 614, true, true));
        assert(api->MechanismInvoke(mechanism) == errAuthorizationSuccess && result == kAuthorizationResultAllow);
        assert([lastReport isEqual:@"GRANT_SENT"]);
        // An in-flight grant cannot be recalled by cancelling the transport.
        // Even a stable original locked screen is insufficient to remove shields.
        assert(!MLCanReleaseGuard(true, true, false, true, true, true));
        assert(!MLCanReleaseGuard(true, false, true, true, true, true)); // Unknown outcome must retain coverage.
        assert(!MLCanReleaseGuard(true, true, true, false, false, true));
        assert(MLCanReleaseGuard(true, true, true, true, true, true));
        api->MechanismDestroy(mechanism); api->PluginDestroy(plugin);
        puts("PASS: no credential/context writes; second invocation denies; cancellation after permit can still emit Allow, so shields await unlock then relock. Mock engine/transport, no real rights requested.");
    }
}
