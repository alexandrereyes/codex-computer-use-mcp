#include <Security/AuthorizationPlugin.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

static unsigned decisions, deactivations;
static OSStatus callbackStatus;
static const char *right;
static OSStatus result(AuthorizationEngineRef engine, AuthorizationResult value) {
    (void)engine;
    assert(value == kAuthorizationResultDeny);
    ++decisions;
    return callbackStatus;
}
static OSStatus deactivated(AuthorizationEngineRef engine) {
    (void)engine;
    ++deactivations;
    return errAuthorizationSuccess;
}
static OSStatus hint(AuthorizationEngineRef engine, AuthorizationString key, const AuthorizationValue **out) {
    (void)engine;
    static AuthorizationValue value;
    if (right && strcmp(key, "authorize-right") == 0) {
        value.length = strlen(right) + 1;
        value.data = (void *)right;
        *out = &value;
        return errAuthorizationSuccess;
    }
    *out = NULL;
    return errAuthorizationDenied;
}
int main(int argc, const char *argv[]) {
    assert(argc == 2 || argc == 3);
    const char *mechanismName = argc == 3 ? argv[2] : "deny";
    void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!handle) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    typedef OSStatus (*Create)(const AuthorizationCallbacks *, AuthorizationPluginRef *, const AuthorizationPluginInterface **);
    Create create = (Create)dlsym(handle, "AuthorizationPluginCreate");
    assert(create);
    AuthorizationCallbacks callbacks = {.version = kAuthorizationCallbacksVersion,
        .SetResult = result, .DidDeactivate = deactivated, .GetHintValue = hint};
    AuthorizationPluginRef plugin;
    const AuthorizationPluginInterface *api;
    assert(create(&callbacks, &plugin, &api) == errAuthorizationSuccess);
    assert(api->version == kAuthorizationPluginInterfaceVersion);
    const char *rights[] = {NULL, "br.com.alexandrem.mac-lock.diagnostic", "system.login.screensaver"};
    for (unsigned i = 0; i < 3; ++i) {
        right = rights[i];
        AuthorizationMechanismRef mechanism;
        assert(api->MechanismCreate(plugin, (AuthorizationEngineRef)&callbacks, mechanismName, &mechanism) == errAuthorizationSuccess);
        callbackStatus = errAuthorizationSuccess;
        assert(api->MechanismInvoke(mechanism) == callbackStatus);
        callbackStatus = errAuthorizationInternal;
        assert(api->MechanismInvoke(mechanism) == callbackStatus);
        assert(api->MechanismDeactivate(mechanism) == errAuthorizationSuccess);
        assert(api->MechanismDestroy(mechanism) == errAuthorizationSuccess);
    }
    assert(decisions == 6 && deactivations == 3);
    assert(api->PluginDestroy(plugin) == errAuthorizationSuccess);
    dlclose(handle);
    puts("PASS: actual built bundle returned only Deny; callback failures propagated; deactivation completed. Mock engine, NOT authd integration.");
    return 0;
}
