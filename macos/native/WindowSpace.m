// Adapted from Lakr233/SkyLightWindow, commit a28588bc5222b8daf6c4b46afb462a5d31495685.
// Copyright (c) 2025 Lakr Aream. MIT notice: SkyLightWindow-LICENSE.txt.
#import "WindowSpace.h"
#include <dlfcn.h>

@implementation MLWindowSpace {
    void *_library;
    int32_t _connection;
    uint64_t _space; // Space IDs are machine-width in CGS; do not truncate to Swift source's Int32.
    void (*_hide)(int32_t, CFArrayRef);
    void (*_destroy)(int32_t, uint64_t);
}
- (BOOL)attachWindows:(NSArray<NSWindow *> *)windows {
    _library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW | RTLD_LOCAL);
    if (!_library) { fputs("REFUSED Space: SkyLight unavailable\n", stderr); return NO; }
    int32_t (*connection)(void) = dlsym(_library, "SLSMainConnectionID");
    // macOS 27 client serializes the second create argument as 32-bit; retain upstream's 1.
    uint64_t (*create)(int32_t, int32_t, CFDictionaryRef) = dlsym(_library, "SLSSpaceCreate");
    // All five mutators have an asynchronous bridge ending in objc_autoreleasePoolPop.
    // Its undefined return register is NOT a CGError (host ABI qualification: ../README.md).
    void (*level)(int32_t, uint64_t, int32_t) = dlsym(_library, "SLSSpaceSetAbsoluteLevel");
    void (*show)(int32_t, CFArrayRef) = dlsym(_library, "SLSShowSpaces");
    void (*add)(int32_t, uint64_t, CFArrayRef, int32_t) = dlsym(_library, "SLSSpaceAddWindowsAndRemoveFromSpaces");
    _hide = dlsym(_library, "SLSHideSpaces");
    _destroy = dlsym(_library, "SLSSpaceDestroy");
    if (!connection || !create || !level || !show || !add || !_hide || !_destroy) {
        fprintf(stderr, "REFUSED Space symbols: connection=%d create=%d level=%d show=%d add=%d hide=%d destroy=%d\n",
            connection != NULL, create != NULL, level != NULL, show != NULL, add != NULL, _hide != NULL, _destroy != NULL);
        return NO;
    }
    NSMutableArray *ids = [NSMutableArray array];
    for (NSWindow *window in windows) {
        if (window.windowNumber <= 0) return NO;
        [ids addObject:@(window.windowNumber)];
    }
    if (!ids.count || (_connection = connection()) <= 0 || !(_space = create(_connection, 1, NULL))) {
        fputs("REFUSED Space: windows/connection/create failed\n", stderr); return NO;
    }
    level(_connection, _space, 400); // Space level, not NSWindow.level.
    show(_connection, (__bridge CFArrayRef)@[@(_space)]);
    add(_connection, _space, (__bridge CFArrayRef)ids, 7);
    fprintf(stderr, "SPACE_ATTACH space=%llu setLevelRequested=1 showRequested=1 addWindowsRequested=1 windows=%lu\n",
        (unsigned long long)_space, (unsigned long)ids.count);
    return YES;
}
- (void)close {
    if (_space) {
        _hide(_connection, (__bridge CFArrayRef)@[@(_space)]);
        _destroy(_connection, _space); // Void API in CGS lifecycle declarations; no fabricated success code.
        fprintf(stderr, "SPACE_CLEANUP space=%llu hideRequested=1 destroyRequested=1\n", (unsigned long long)_space);
        _space = 0;
    }
    if (_library) { dlclose(_library); _library = NULL; }
}
- (void)dealloc { [self close]; }
@end
