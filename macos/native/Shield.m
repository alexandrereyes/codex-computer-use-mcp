#import "Shield.h"
#import "WindowSpace.h"
#include "Attempt.h"
#include <unistd.h>
#include <libproc.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hidsystem/IOHIDLib.h>

@interface MLShield () {
    CFMachPortRef _tap;
    CFRunLoopSourceRef _tapSource;
    NSMutableArray<NSWindow *> *_windows;
    NSMutableDictionary<NSNumber *, NSValue *> *_syntheticSources;
    BOOL _ready, _stopping;
    id _screenObserver;
    NSTimer *_lockTimer;
    NSUInteger _displayCount;
    CFAbsoluteTime _lockedSince;
    IOHIDManagerRef _hid;
    NSString *_failureReason;
    NSUInteger _suppressedEvents;
    MLCoverageObservation _coverageObservation;
    BOOL _previouslyVisible;
    MLWindowSpace *_space;
}
- (CGEventRef)filter:(CGEventRef)event type:(CGEventType)type;
- (void)abort:(NSString *)reason;
- (BOOL)loginCoverageVisible;
- (void)tearDown;
@end
static CGEventRef filter(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    (void)proxy;
    return [(__bridge MLShield *)context filter:event type:type];
}
static void hidInput(void *context, IOReturn result, void *sender, IOHIDValueRef value) {
    (void)sender; (void)value; // Never read/log key or pointer values.
    [(__bridge MLShield *)context abort:result == kIOReturnSuccess ? @"hid-input" : @"hid-monitor-error"];
}
@implementation MLShield
- (BOOL)ready {
    return _ready && self.protectionIntact;
}
- (BOOL)protectionIntact {
    // Window metadata is not proof of visibility above the secure login surface.
    _failureReason = nil;
    _coverageObservation = MLCoverageFailed; // Structural/input failures must never become pending.
    MLLockState state = MLScreenLockState();
    if (state == MLLockUnknown) { _failureReason = @"lock-state-unknown"; return NO; }
    if (state == MLLockUnlocked && (!_possibleGrant || _grantReported)) _observedUnlock = YES;
    if (!_tap) { _failureReason = @"event-tap-missing"; return NO; }
    if (!_hid) { _failureReason = @"hid-manager-missing"; return NO; }
    if (!CGEventTapIsEnabled(_tap)) { _failureReason = @"event-tap-disabled"; return NO; }
    if (NSScreen.screens.count != _displayCount) { _failureReason = @"display-count-changed"; return NO; }
    if (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted) {
        _failureReason = @"input-monitoring-access-lost"; return NO;
    }
    BOOL overlayVisible = _windows.count > 0;
    for (NSWindow *window in _windows) overlayVisible &= (window.occlusionState & NSWindowOcclusionStateVisible) != 0;
    NSArray *info = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    NSInteger minimumLayer = CGShieldingWindowLevel() + 1;
    for (NSScreen *screen in NSScreen.screens) {
        CGRect frame = CGDisplayBounds([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]);
        BOOL covered = NO;
        for (NSWindow *own in _windows) for (NSDictionary *window in info) {
            if ([window[(__bridge NSString *)kCGWindowNumber] integerValue] != own.windowNumber) continue;
            CGRect bounds;
            if (CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(__bridge NSString *)kCGWindowBounds], &bounds) &&
                CGRectContainsRect(bounds, frame) && [window[(__bridge NSString *)kCGWindowAlpha] doubleValue] >= 1 &&
                [window[(__bridge NSString *)kCGWindowLayer] integerValue] >= minimumLayer) covered = YES;
        }
        if (!covered) {
            // Diagnose only our windows, from the exact CG snapshot that failed.
            NSMutableArray *ownWindows = [NSMutableArray array];
            for (NSWindow *own in _windows) {
                NSDictionary *entry = nil;
                for (NSDictionary *window in info)
                    if ([window[(__bridge NSString *)kCGWindowNumber] integerValue] == own.windowNumber) { entry = window; break; }
                id rawBounds = entry[(__bridge NSString *)kCGWindowBounds];
                id alpha = entry[(__bridge NSString *)kCGWindowAlpha], layer = entry[(__bridge NSString *)kCGWindowLayer];
                CGRect actual;
                BOOL decoded = rawBounds && CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)rawBounds, &actual);
                [ownWindows addObject:@{
                    @"windowID": @(own.windowNumber), @"found": @(entry != nil),
                    @"reportedBounds": rawBounds ?: NSNull.null, @"boundsValid": @(decoded),
                    @"containsDisplay": @(decoded && CGRectContainsRect(actual, frame)),
                    @"alpha": alpha ?: NSNull.null, @"alphaPass": @([alpha doubleValue] >= 1),
                    @"layer": layer ?: NSNull.null, @"layerPass": @([layer integerValue] >= minimumLayer),
                    @"appKitFrame": NSStringFromRect(own.frame), @"appKitLevel": @(own.level),
                    @"appKitAlpha": @(own.alphaValue), @"appKitVisible": @(own.visible),
                    @"occlusionState": @(own.occlusionState),
                    @"occlusionVisible": @((own.occlusionState & NSWindowOcclusionStateVisible) != 0)
                }];
            }
            NSDictionary *diagnostic = @{
                @"time": NSDate.date.description, @"display": screen.deviceDescription[@"NSScreenNumber"],
                @"expectedBounds": CFBridgingRelease(CGRectCreateDictionaryRepresentation(frame)),
                @"screenAppKitFrame": NSStringFromRect(screen.frame), @"scale": @(screen.backingScaleFactor),
                @"minimumLayer": @(minimumLayer), @"lockState": @(state), @"displayCount": @(_displayCount),
                @"ownWindowCount": @(_windows.count), @"snapshotAvailable": @(info != nil), @"windows": ownWindows
            };
            NSData *json = [NSJSONSerialization dataWithJSONObject:diagnostic options:NSJSONWritingSortedKeys error:NULL];
            fprintf(stderr, "MacLock coverage-snapshot %s\n", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
            _failureReason = [NSString stringWithFormat:@"window-coverage-metadata-missing display=%u",
                [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]];
            return NO;
        }
    }
    if (!_displayCount) _failureReason = @"no-displays";
    if (!_displayCount) return NO;
    // Reuse this check's lock state; the UI and lock flags transition separately.
    BOOL loginVisible = state == MLLockLocked && MLGraphicalSessionActive() && MLLoginPID() > 1 && MLLoginUIShown();
    _coverageObservation = MLObserveCoverage(state, loginVisible, overlayVisible, _possibleGrant, _previouslyVisible);
    if (_coverageObservation == MLCoverageVisible) _previouslyVisible = YES;
    if (_coverageObservation == MLCoveragePending || _coverageObservation == MLCoverageFailed) {
        _failureReason = _coverageObservation == MLCoveragePending ? @"transition-visibility-pending" :
            (state == MLLockLocked ? @"login-surface-not-observable" : @"window-occluded");
        return NO;
    }
    return YES;
}
- (BOOL)transitionPending { return !_stopping && _coverageObservation == MLCoveragePending; }
- (BOOL)unlockedCoverageVisible { return !_stopping && _coverageObservation == MLCoverageVisible; }
- (NSUInteger)suppressedEvents { return _suppressedEvents; }
- (BOOL)stopping { return _stopping; }
- (NSString *)failureReason { return _failureReason ?: @"coverage-or-input-readiness"; }
- (void)rememberSource:(pid_t)pid {
    MLController identity;
    if (MLCaptureController(pid, &identity))
        _syntheticSources[@(pid)] = [NSValue valueWithBytes:&identity objCType:@encode(MLController)];
}
- (BOOL)knownSource:(pid_t)pid {
    NSValue *value = _syntheticSources[@(pid)];
    MLController old, current;
    if (pid <= 1 || !MLCaptureController(pid, &current)) return NO;
    if (value) {
        [value getValue:&old size:sizeof(old)];
        if (old.pid == current.pid && old.uid == current.uid && old.startSeconds == current.startSeconds &&
            old.startMicroseconds == current.startMicroseconds) return YES;
    }
    // The official service can start/restart after the guard. Verify its live code,
    // not a process name or event marker; cache only this PID/start identity.
    if (_stopping || current.uid != getuid() ||
        !MLCodeMatches(pid, @"identifier \"com.openai.sky.CUAService\" and anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\"")) return NO;
    _syntheticSources[@(pid)] = [NSValue valueWithBytes:&current objCType:@encode(MLController)];
    return YES;
}
- (void)coverDisplays {
    // Build new windows before removing old coverage when geometry changes.
    NSMutableArray *next = [NSMutableArray array];
    for (NSScreen *screen in NSScreen.screens) {
        NSWindow *window = [[NSWindow alloc] initWithContentRect:screen.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        window.backgroundColor = NSColor.blackColor;
        window.opaque = YES; window.hasShadow = NO;
        window.animationBehavior = NSWindowAnimationBehaviorNone;
        window.ignoresMouseEvents = YES; // Input tap handles physical input; synthetic actions can reach their targets.
        window.canBecomeVisibleWithoutLogin = YES;
        window.level = CGShieldingWindowLevel() + 1;
        window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
        [window orderFrontRegardless]; [window displayIfNeeded];
        [next addObject:window];
    }
    for (NSWindow *old in _windows) [old close];
    _windows = next;
    _displayCount = next.count;
}
- (BOOL)startInputGuard {
    if (!CGPreflightPostEventAccess() || !AXIsProcessTrusted()) { _failureReason = @"accessibility-or-posting-access"; return NO; }
    if (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted) { _failureReason = @"input-monitoring-access"; return NO; }
    _hid = IOHIDManagerCreate(NULL, kIOHIDOptionsTypeNone);
    NSArray *devices = @[
        @{ @kIOHIDDeviceUsagePageKey: @1, @kIOHIDDeviceUsageKey: @6 }, // keyboard
        @{ @kIOHIDDeviceUsagePageKey: @1, @kIOHIDDeviceUsageKey: @2 }, // mouse
        @{ @kIOHIDDeviceUsagePageKey: @1, @kIOHIDDeviceUsageKey: @1 }, // pointer
        @{ @kIOHIDDeviceUsagePageKey: @13, @kIOHIDDeviceUsageKey: @5 }, // touchpad
        @{ @kIOHIDDeviceUsagePageKey: @13, @kIOHIDDeviceUsageKey: @2 } // pen
    ];
    IOHIDManagerSetDeviceMatchingMultiple(_hid, (__bridge CFArrayRef)devices);
    IOHIDManagerRegisterInputValueCallback(_hid, hidInput, (__bridge void *)self);
    IOHIDManagerScheduleWithRunLoop(_hid, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    if (IOHIDManagerOpen(_hid, kIOHIDOptionsTypeNone) != kIOReturnSuccess) { _failureReason = @"hid-open-failed"; return NO; }
    _syntheticSources = [NSMutableDictionary dictionary];
    [self rememberSource:getpid()];
    if (_companion > 1) [self rememberSource:_companion];
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) |
        CGEventMaskBit(kCGEventFlagsChanged) | CGEventMaskBit(kCGEventMouseMoved) |
        CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) |
        CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp) |
        CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp) |
        CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventRightMouseDragged) |
        CGEventMaskBit(kCGEventOtherMouseDragged) | CGEventMaskBit(kCGEventScrollWheel);
    _tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, filter, (__bridge void *)self);
    if (!_tap) { _failureReason = @"event-tap-create-failed"; return NO; }
    _tapSource = CFMachPortCreateRunLoopSource(NULL, _tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), _tapSource, kCFRunLoopCommonModes);
    _ready = YES;
    return CGEventTapIsEnabled(_tap);
}
- (BOOL)start {
    if (!MLGraphicalSessionActive() || MLScreenLockState() != MLLockLocked) { _failureReason = @"not-active-locked-session"; return NO; }
    if (![self loginCoverageVisible]) { _failureReason = @"login-surface-not-observable"; return NO; }
    if (![self startInputGuard]) return NO;
    [self coverDisplays];
    if (_usesPrivateSpace) {
        _space = [MLWindowSpace new];
        if (![_space attachWindows:_windows]) {
            _failureReason = @"private-space-setup-failed";
            [self tearDown]; // Before any permit: close windows and release even a partially created Space.
            return NO;
        }
    }
    __weak MLShield *weak = self;
    _screenObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidChangeScreenParametersNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        (void)note;
        [weak abort:@"display-change"];
        // Keep the existing curtain until relock; hotplug/replacement windows are not qualified.
    }];
    _ready = _windows.count > 0;
    for (NSWindow *window in _windows) _ready &= window.visible;
    // WindowServer acknowledgement is checked by ready on subsequent run-loop ticks.
    return _ready && CGEventTapIsEnabled(_tap);
}
- (CGEventRef)filter:(CGEventRef)event type:(CGEventType)type {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        fprintf(stderr, "GUARD event-tap-disabled cause=%s\n", type == kCGEventTapDisabledByTimeout ? "timeout" : "user-input");
        [self abort:@"input-tap-disabled"]; return event;
    }
    pid_t pid = (pid_t)CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
    // Own relock events must pass even after cancellation. No marker-only exemption.
    if ((pid == getpid() || pid == _companion) && [self knownSource:pid]) return event;
    if (!_stopping && [self knownSource:pid]) return event;
    ++_suppressedEvents;
    if (!_stopping) fprintf(stderr, "MacLock rejected event sourcePID=%d type=%u\n", pid, (unsigned)type);
    [self abort:pid == 0 ? @"hardware-or-unattributed-input" : @"unattributed-software-input"];
    return NULL; // Suppress before delivery, then relock; never call it proven physical input.
}
- (void)abort:(NSString *)reason {
    if (_stopping) return;
    _failureReason = reason; // Preserve the first cause if the readiness timer runs before onAbort.
    _stopping = YES; _ready = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.onAbort) self.onAbort(reason); });
}
- (BOOL)loginCoverageVisible {
    // System-protected state, not ownership of every foreground compositor surface.
    // Keep loginwindow's live Apple-signature check and reject unknown lock/UI state.
    return MLGraphicalSessionActive() && MLScreenLockState() == MLLockLocked &&
        MLLoginPID() > 1 && MLLoginUIShown();
}
- (void)relockThen:(void (^)(void))completion {
    _stopping = YES; _ready = NO;
    if (_lockTimer) return;
    _lockedSince = 0;
    if (MLScreenLockState() == MLLockUnlocked && (!_possibleGrant || _grantReported)) _observedUnlock = YES;
    if (!_possibleGrant || _observedUnlock) MLPostLock();
    __block unsigned tick = 0;
    _lockTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        MLLockState state = MLScreenLockState();
        if (state == MLLockLocked) {
            if (!self->_lockedSince) self->_lockedSince = MLMonotonicTime();
            BOOL stable = MLMonotonicTime() - self->_lockedSince >= 1;
            if (MLCanReleaseGuard(self->_possibleGrant, self->_grantReported, self->_observedUnlock, YES, stable, [self loginCoverageVisible])) {
                [timer invalidate]; self->_lockTimer = nil; completion(); return;
            }
        } else {
            if (state == MLLockUnlocked && (!self->_possibleGrant || self->_grantReported)) self->_observedUnlock = YES;
            self->_lockedSince = 0;
            MLPostLock();
        }
        // Never hide coverage on timeout. Retry request; the controller reports failure.
        if (++tick % 20 == 0 && (!self->_possibleGrant || self->_observedUnlock)) MLPostLock();
    }];
}
- (BOOL)removeAfterConfirmedLock {
    if (MLScreenLockState() != MLLockLocked) return NO;
    [self tearDown]; return YES;
}
- (void)cancelBeforeGrant {
    // Only paths that never arm/grant: failed start or bounded visual trials.
    [self tearDown];
}
- (void)tearDown {
    _ready = NO; _stopping = YES;
    for (NSWindow *window in _windows) [window close];
    [_windows removeAllObjects];
    [_space close]; _space = nil; // One Space per operation, released after its windows close.
    if (_tapSource) { CFRunLoopRemoveSource(CFRunLoopGetMain(), _tapSource, kCFRunLoopCommonModes); CFRelease(_tapSource); _tapSource = NULL; }
    if (_tap) { CFMachPortInvalidate(_tap); CFRelease(_tap); _tap = NULL; }
    if (_hid) {
        IOHIDManagerUnscheduleFromRunLoop(_hid, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        IOHIDManagerClose(_hid, kIOHIDOptionsTypeNone); CFRelease(_hid); _hid = NULL;
    }
    if (_screenObserver) [NSNotificationCenter.defaultCenter removeObserver:_screenObserver];
    _screenObserver = nil;
}
@end
