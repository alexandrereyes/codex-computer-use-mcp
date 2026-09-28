#import "WindowSpace.h"
#include <dlfcn.h>
#include <assert.h>
#include <string.h>

// Link-time SPI fixtures: no NSWindow, real SkyLight call or Space is created.
@interface SpaceWindowFixture : NSObject
@property(nonatomic) NSInteger windowNumber;
@end
@implementation SpaceWindowFixture
@end
static NSMutableArray *calls;
static BOOL failCreate, missingHide;
static const uint64_t sid = UINT64_C(0x100000007);
static int library;
static int32_t connection(void) { [calls addObject:@"connection"]; return 5; }
static uint64_t create(int32_t cid, int32_t flags, CFDictionaryRef options) {
    assert(cid == 5 && flags == 1 && options == NULL);
    [calls addObject:@"create"]; return failCreate ? 0 : sid;
}
static void level(int32_t cid, uint64_t space, int32_t value) {
    assert(cid == 5 && space == sid && value == 400); [calls addObject:@"level"];
}
static void show(int32_t cid, CFArrayRef spaces) {
    assert(cid == 5 && [(__bridge NSArray *)spaces isEqualToArray:@[@(sid)]]); [calls addObject:@"show"];
}
static void add(int32_t cid, uint64_t space, CFArrayRef windows, int32_t flags) {
    NSArray *expected = @[@17, @18];
    assert(cid == 5 && space == sid && flags == 7 && [(__bridge NSArray *)windows isEqualToArray:expected]);
    [calls addObject:@"add"];
}
static void hide(int32_t cid, CFArrayRef spaces) {
    assert(cid == 5 && [(__bridge NSArray *)spaces isEqualToArray:@[@(sid)]]); [calls addObject:@"hide"];
}
static void destroy(int32_t cid, uint64_t space) {
    assert(cid == 5 && space == sid); [calls addObject:@"destroy"];
}
void *dlopen(const char *path, int flags) {
    assert(strstr(path, "SkyLight.framework") && (flags & RTLD_NOW)); [calls addObject:@"open"]; return &library;
}
void *dlsym(void *handle, const char *name) {
    assert(handle == &library);
    if (!strcmp(name, "SLSMainConnectionID")) return (void *)connection;
    if (!strcmp(name, "SLSSpaceCreate")) return (void *)create;
    if (!strcmp(name, "SLSSpaceSetAbsoluteLevel")) return (void *)level;
    if (!strcmp(name, "SLSShowSpaces")) return (void *)show;
    if (!strcmp(name, "SLSSpaceAddWindowsAndRemoveFromSpaces")) return (void *)add;
    if (!strcmp(name, "SLSHideSpaces")) return missingHide ? NULL : (void *)hide;
    if (!strcmp(name, "SLSSpaceDestroy")) return (void *)destroy;
    assert(!"Unexpected SPI"); return NULL;
}
int dlclose(void *handle) { assert(handle == &library); [calls addObject:@"close"]; return 0; }
int main(void) {
    @autoreleasepool {
        SpaceWindowFixture *a = [SpaceWindowFixture new], *b = [SpaceWindowFixture new];
        a.windowNumber = 17; b.windowNumber = 18;
        NSArray *windows = @[a, b];
        calls = [NSMutableArray array];
        MLWindowSpace *space = [MLWindowSpace new];
        assert([space attachWindows:(id)windows]);
        [space close]; [space close]; space = nil;
        NSArray *expected = @[@"open", @"connection", @"create", @"level", @"show", @"add", @"hide", @"destroy", @"close"];
        assert([calls isEqualToArray:expected]); // Exactly one release; SID is not truncated.
        [calls removeAllObjects]; failCreate = YES; space = [MLWindowSpace new];
        assert(![space attachWindows:(id)windows]); [space close]; space = nil;
        expected = @[@"open", @"connection", @"create", @"close"];
        assert([calls isEqualToArray:expected]);
        [calls removeAllObjects]; failCreate = NO; missingHide = YES; space = [MLWindowSpace new];
        assert(![space attachWindows:(id)windows]); [space close]; space = nil;
        expected = @[@"open", @"close"];
        assert([calls isEqualToArray:expected]);
        puts("PASS: one Space/two windows, SID64, void mutators, exactly-once teardown; create/symbol failures refuse (SPI fixtures only).");
        return 0;
    }
}
