#import "Runtime.h"
#include <Security/AuthorizationPlugin.h>
#include <os/log.h>
#include <sys/socket.h>
#include <unistd.h>

typedef struct { const AuthorizationCallbacks *callbacks; } MLPlugin;
typedef struct { MLPlugin *plugin; AuthorizationEngineRef engine; } MLMechanism;
static OSStatus pluginDestroy(AuthorizationPluginRef ref) { free(ref); return errAuthorizationSuccess; }
static OSStatus mechanismCreate(AuthorizationPluginRef plugin, AuthorizationEngineRef engine, AuthorizationMechanismId name, AuthorizationMechanismRef *out) {
    if (strcmp(name, "operation") != 0) return errAuthorizationInternal;
    MLMechanism *m = calloc(1, sizeof(*m)); if (!m) return errAuthorizationInternal;
    m->plugin = plugin; m->engine = engine; *out = m; return errAuthorizationSuccess;
}
static BOOL correctRight(MLMechanism *m) {
    const AuthorizationValue *value = NULL;
    const char *right = "system.login.screensaver";
    size_t n = strlen(right);
    return m->plugin->callbacks->GetHintValue(m->engine, "authorize-right", &value) == errAuthorizationSuccess &&
        value && value->data && (value->length == n || (value->length == n + 1 && ((char *)value->data)[n] == 0)) &&
        memcmp(value->data, right, n) == 0;
}
static OSStatus mechanismInvoke(AuthorizationMechanismRef ref) {
    @autoreleasepool {
        MLMechanism *m = ref;
        AuthorizationResult decision = kAuthorizationResultDeny;
        const AuthorizationValue *value = NULL;
        int client = -1;
        if (correctRight(m) && m->plugin->callbacks->GetHintValue(m->engine, "client-pid", &value) == errAuthorizationSuccess &&
            value && value->data && value->length == sizeof(client)) memcpy(&client, value->data, sizeof(client));
        NSDictionary *config = MLReadConfig();
        SecRequirementRef requirement = MLCopyNativeRequirement();
        int fd = -1;
        BOOL permitReceived = NO;
        NSString *nonce = NSUUID.UUID.UUIDString;
        if (config && requirement && client > 1) {
            fd = MLConnect([MLInstallRoot stringByAppendingPathComponent:@"run/authorization.sock"]);
            if (fd >= 0 && MLPeerMatches(fd, requirement) && MLWriteLine(fd, [NSString stringWithFormat:@"AUTHORIZE %d %@", client, nonce])) {
                NSString *response = MLReadLine(fd);
                NSString *expected = [NSString stringWithFormat:@"ALLOW %u %@", [config[@"uid"] unsignedIntValue], nonce];
                if ([response isEqual:expected]) {
                    permitReceived = YES;
                    decision = kAuthorizationResultAllow;
                }
            }
        }
        OSStatus status = m->plugin->callbacks->SetResult(m->engine, decision);
        NSString *report = decision == kAuthorizationResultAllow ? (status == errAuthorizationSuccess ? @"GRANT_SENT" : @"GRANT_UNCERTAIN") : @"NO_GRANT";
        if (permitReceived) MLWriteLine(fd, report);
        if (requirement) CFRelease(requirement);
        if (fd >= 0) close(fd);
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "MacLock operation decision=%u status=%d", decision, (int)status);
        return status;
    }
}
static OSStatus mechanismDeactivate(AuthorizationMechanismRef ref) {
    MLMechanism *m = ref; return m->plugin->callbacks->DidDeactivate(m->engine);
}
static OSStatus mechanismDestroy(AuthorizationMechanismRef ref) { free(ref); return errAuthorizationSuccess; }
static const AuthorizationPluginInterface interface = {kAuthorizationPluginInterfaceVersion, pluginDestroy, mechanismCreate, mechanismInvoke, mechanismDeactivate, mechanismDestroy};
OSStatus AuthorizationPluginCreate(const AuthorizationCallbacks *callbacks, AuthorizationPluginRef *plugin, const AuthorizationPluginInterface **out) {
    MLPlugin *p = calloc(1, sizeof(*p)); if (!p) return errAuthorizationInternal;
    p->callbacks = callbacks; *plugin = p; *out = &interface; return errAuthorizationSuccess;
}
