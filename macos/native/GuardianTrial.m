#import "Shield.h"
#import "WindowSpace.h"
#include <signal.h>
#include <unistd.h>

// Trial-only marker: a sleeping display cannot be mistaken for this surface.
static void markTrialWindows(NSString *text) {
    for (NSWindow *window in NSApp.windows) {
        window.backgroundColor = [NSColor colorWithCalibratedRed:1 green:0 blue:0.65 alpha:1];
        NSTextField *label = [NSTextField labelWithString:text];
        label.font = [NSFont boldSystemFontOfSize:40];
        label.textColor = NSColor.whiteColor;
        label.alignment = NSTextAlignmentCenter;
        NSRect bounds = window.contentView.bounds;
        label.frame = NSMakeRect(0, NSMidY(bounds) - 30, NSWidth(bounds), 60);
        [window.contentView addSubview:label];
        [window displayIfNeeded];
    }
}

// One metadata sample, not screenshots/titles or proof of physical visibility.
static void describeTrialOrder(void) {
    NSArray *info = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    for (NSWindow *own in NSApp.windows) {
        NSDictionary *entry = nil;
        for (NSDictionary *window in info)
            if ([window[(__bridge NSString *)kCGWindowNumber] integerValue] == own.windowNumber) { entry = window; break; }
        CGRect frame;
        if (!entry || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)entry[(__bridge NSString *)kCGWindowBounds], &frame)) continue;
        NSDictionary *preceding = nil;
        for (NSDictionary *window in info) {
            if (window == entry) break;
            CGRect bounds;
            if ([window[(__bridge NSString *)kCGWindowOwnerPID] intValue] != getpid() &&
                [window[(__bridge NSString *)kCGWindowAlpha] doubleValue] > 0 &&
                CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(__bridge NSString *)kCGWindowBounds], &bounds) &&
                CGRectIntersectsRect(frame, bounds)) { preceding = window; break; }
        }
        printf("TRIAL_ORDER window=%ld level=%ld appkitOcclusionVisible=%d precedingOverlapPID=%d precedingOverlapLevel=%ld sessionMetadataOnly=1\n",
            (long)own.windowNumber, [entry[(__bridge NSString *)kCGWindowLayer] longValue],
            (own.occlusionState & NSWindowOcclusionStateVisible) != 0,
            [preceding[(__bridge NSString *)kCGWindowOwnerPID] intValue], [preceding[(__bridge NSString *)kCGWindowLayer] longValue]);
    }
}

// GUI assay only: no lease, authorizer, Return, lock request or installation.
int MLGuardianTrial(void) {
    @autoreleasepool {
        alarm(15); // No grant is possible: process exit removes only the assay's UI.
        if (getuid() == 0 || !MLGraphicalSessionActive() || MLScreenLockState() != MLLockLocked) {
            fputs("REFUSED: run as the graphical user with the Mac already locked\n", stderr);
            return 3;
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        MLShield *shield = [MLShield new];
        __block BOOL announced = NO, inputSeen = NO, finished = NO;
        __block double visibleSince = 0;
        double started = MLMonotonicTime();
        void (^finish)(BOOL, NSString *) = ^(BOOL ok, NSString *reason) {
            if (finished) return;
            finished = YES;
            MLLockState stillLocked = MLScreenLockState();
            [shield cancelBeforeGrant]; // This assay never requests or grants authentication.
            printf("END reason=%s inputObserved=%d lockedAfter=%ld\n", reason.UTF8String, inputSeen, (long)stillLocked);
            fflush(stdout);
            exit(ok && stillLocked == MLLockLocked ? 0 : 4);
        };
        shield.onAbort = ^(NSString *reason) {
            BOOL input = [reason isEqual:@"hid-input"] || [reason isEqual:@"hardware-or-unattributed-input"] ||
                [reason isEqual:@"unattributed-software-input"];
            if (!input || !announced) { finish(NO, reason); return; }
            inputSeen = YES;
            printf("INPUT category=%s (not proof of physical provenance)\n", reason.UTF8String);
            fflush(stdout);
            // Keep the tap and coverage until the fixed deadline, including key-up events.
        };
        if (![shield start]) {
            NSString *reason = shield.failureReason;
            [shield cancelBeforeGrant];
            fprintf(stderr, "REFUSED: %s\n", reason.UTF8String);
            return 3;
        }
        markTrialWindows(@"MACLOCK — TESTE 10s");
        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            if (!MLGraphicalSessionActive() || MLScreenLockState() != MLLockLocked) { finish(NO, @"session-changed"); return; }
            double now = MLMonotonicTime();
            if (!announced && shield.ready) {
                announced = YES; visibleSince = now;
                printf("READY displays=%lu duration=10s no-authentication metadataOnly=1 visualCoverage=unverified\n", (unsigned long)NSScreen.screens.count);
                describeTrialOrder();
                fflush(stdout);
            }
            if (!announced && now - started >= 3)
                finish(NO, [@"readiness-timeout detail=" stringByAppendingString:shield.failureReason]);
            else if (announced && !shield.protectionIntact)
                finish(NO, [@"coverage-or-input-lost detail=" stringByAppendingString:shield.failureReason]);
            else if (announced && now - visibleSince >= 10) finish(YES, @"duration-complete");
        }];
        [NSApp run];
        return 4;
    }
}

// Both trials use manual authentication. Only the explicit input/relock mode requests lock.
static NSString *spaceGeometry(NSArray<NSWindow *> *windows, NSDictionary *expected, MLLockState state) {
    NSArray *info = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    NSMutableArray *rows = [NSMutableArray array];
    for (NSWindow *own in windows) {
        NSDictionary *entry = nil, *target = expected[@(own.windowNumber)];
        for (NSDictionary *window in info)
            if ([window[(__bridge NSString *)kCGWindowNumber] integerValue] == own.windowNumber) { entry = window; break; }
        id raw = entry[(__bridge NSString *)kCGWindowBounds];
        CGRect actual, frame;
        BOOL decoded = raw && CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)raw, &actual);
        BOOL hasTarget = target && CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)target[@"bounds"], &frame);
        [rows addObject:@{ @"id": @(own.windowNumber), @"found": @(entry != nil), @"expected": target ?: NSNull.null,
            @"reportedBounds": raw ?: NSNull.null, @"containsDisplay": @(decoded && hasTarget && CGRectContainsRect(actual, frame)),
            @"appKitFrame": NSStringFromRect(own.frame), @"occlusionVisible": @((own.occlusionState & NSWindowOcclusionStateVisible) != 0),
            @"alpha": entry[(__bridge NSString *)kCGWindowAlpha] ?: NSNull.null,
            @"layer": entry[(__bridge NSString *)kCGWindowLayer] ?: NSNull.null }];
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"locked": @(state), @"snapshotAvailable": @(info != nil), @"windows": rows}
        options:NSJSONWritingSortedKeys error:NULL];
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}

static int transitionTrial(BOOL withInput, BOOL experimentalSpace) {
    @autoreleasepool {
        signal(SIGALRM, SIG_DFL);
        alarm(65); // Process exit removes these trial windows even if the run loop stalls.
        if (getuid() == 0 || !MLGraphicalSessionActive() || MLScreenLockState() != MLLockLocked) {
            fputs("REFUSED: run as the graphical user with the Mac already locked\n", stderr);
            return 3;
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        MLShield *shield = [MLShield new];
        [shield coverDisplays]; // Deliberately no start: no event tap, HID, lease or authentication.
        markTrialWindows(@"MACLOCK — TRANSIÇÃO MANUAL");
        NSArray<NSWindow *> *trialWindows = NSApp.windows.copy;
        NSMutableDictionary *expected = [NSMutableDictionary dictionary];
        MLWindowSpace *space = nil;
        if (experimentalSpace) {
            for (NSWindow *window in trialWindows) {
                NSScreen *screen = window.screen;
                if (screen) expected[@(window.windowNumber)] = @{
                    @"display": screen.deviceDescription[@"NSScreenNumber"], @"scale": @(screen.backingScaleFactor),
                    @"bounds": CFBridgingRelease(CGRectCreateDictionaryRepresentation(CGDisplayBounds([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]))) };
                // Geometry marker only: leave login UI readable and all input untouched.
                window.backgroundColor = NSColor.clearColor; window.opaque = NO;
                for (NSView *view in window.contentView.subviews) {
                    view.frame = NSMakeRect(0, 20, NSWidth(window.contentView.bounds), 60);
                    if ([view isKindOfClass:NSTextField.class]) ((NSTextField *)view).stringValue = @"MACLOCK — SPACE EXPERIMENTAL";
                }
                NSBox *border = [[NSBox alloc] initWithFrame:window.contentView.bounds];
                border.boxType = NSBoxCustom; border.titlePosition = NSNoTitle;
                border.transparent = NO; border.borderWidth = 12;
                border.borderColor = NSColor.magentaColor; border.fillColor = NSColor.clearColor;
                [window.contentView addSubview:border positioned:NSWindowBelow relativeTo:nil]; [window displayIfNeeded];
            }
            space = [MLWindowSpace new];
            if (expected.count != trialWindows.count || ![space attachWindows:trialWindows]) {
                [shield cancelBeforeGrant]; [space close]; return 3;
            }
        }
        double started = MLMonotonicTime();
        __block BOOL unlockedSeen = NO;
        __block double relockedSince = 0;
        __block NSString *previous = nil, *previousGeometry = nil;
        __block BOOL inputReady = NO, inputSeen = NO, relocking = NO;
        __block double unlockedAt = 0, guardAt = 0, relockAt = 0;
        printf("START pid=%d time=%s durationMax=60s hardLimit=65s mode=%s visualCoverage=unverified\n",
            getpid(), NSDate.date.description.UTF8String, experimentalSpace ? "manual-private-space-geometry" : (withInput ? "manual-unlock-input-auto-relock" : "manual-only"));
        fflush(stdout);
        void (^finish)(BOOL, NSString *) = ^(BOOL complete, NSString *reason) {
            MLLockState locked = MLScreenLockState();
            [shield cancelBeforeGrant]; // No grant exists; bounded trial cleanup is reported even on failure.
            [space close]; // Close windows first, then request hide/destroy; void SPI has no confirmation return.
            printf("END elapsed=%.3f reason=%s unlockedSeen=%d lockedAfter=%ld visualCoverage=unverified inputGuard=%d suppressedEvents=%lu cleanup=trial-resources-only\n",
                MLMonotonicTime() - started, reason.UTF8String, unlockedSeen, (long)locked, inputReady,
                (unsigned long)shield.suppressedEvents);
            fflush(stdout);
            exit(complete && locked == MLLockLocked ? 0 : 4);
        };
        __attribute__((objc_precise_lifetime)) NSMutableArray *signalSources = [NSMutableArray array];
        if (experimentalSpace) for (NSNumber *number in @[@(SIGTERM), @(SIGINT)]) {
            signal(number.intValue, SIG_IGN);
            dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, number.intValue, 0, dispatch_get_main_queue());
            dispatch_source_set_event_handler(source, ^{ finish(NO, @"interrupted"); });
            [signalSources addObject:source]; dispatch_resume(source);
        }
        void (^requestRelock)(NSString *, BOOL) = ^(NSString *reason, BOOL input) {
            if (relocking) return;
            relocking = YES; inputSeen = input; relockAt = MLMonotonicTime();
            printf("RELOCK_REQUEST elapsed=%.3f cause=%s inputReady=%d\n", relockAt - started, reason.UTF8String, inputReady);
            fflush(stdout);
            [shield relockThen:^{
                BOOL qualified = inputReady && inputSeen && shield.suppressedEvents > 0 && shield.protectionIntact;
                finish(qualified, qualified ? @"input-and-relock-confirmed" : @"relock-confirmed-input-unqualified");
            }];
        };
        if (withInput) shield.onAbort = ^(NSString *reason) {
            BOOL input = [reason isEqual:@"hid-input"] || [reason isEqual:@"hardware-or-unattributed-input"] ||
                [reason isEqual:@"unattributed-software-input"];
            requestRelock(reason, input);
        };
        [NSTimer scheduledTimerWithTimeInterval:experimentalSpace ? 0.05 : 0.1 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            if (!MLGraphicalSessionActive()) { finish(NO, @"graphical-session-changed"); return; }
            MLLockState locked = MLScreenLockState();
            if (locked == MLLockUnknown) { finish(NO, @"lock-state-unknown"); return; }
            double now = MLMonotonicTime();
            if (experimentalSpace) {
                NSString *geometry = spaceGeometry(trialWindows, expected, locked);
                if (![geometry isEqual:previousGeometry]) {
                    printf("SPACE_GEOMETRY elapsed=%.3f %s\n", now - started, geometry.UTF8String);
                    fflush(stdout); previousGeometry = geometry;
                }
            }
            NSMutableString *state = [NSMutableString stringWithFormat:@"locked=%ld windows(id:occlusionVisible)=", (long)locked];
            for (NSWindow *window in NSApp.windows)
                [state appendFormat:@" %ld:%d", (long)window.windowNumber,
                    (window.occlusionState & NSWindowOcclusionStateVisible) != 0];
            if (![state isEqual:previous]) {
                printf("STATE elapsed=%.3f %s\n", now - started, state.UTF8String);
                fflush(stdout); previous = [state copy];
            }
            if (locked == MLLockUnlocked) {
                unlockedSeen = YES; relockedSince = 0;
                if (!unlockedAt) unlockedAt = now;
            }
            else if (unlockedSeen && !relockedSince) relockedSince = now;
            if (withInput) {
                if (!relocking && !guardAt && locked == MLLockUnlocked && now - unlockedAt >= 2) {
                    guardAt = now;
                    if (![shield startInputGuard] || !shield.ready) requestRelock(shield.failureReason, NO);
                    else {
                        inputReady = YES;
                        printf("INPUT_READY elapsed=%.3f action=small-pointer-movement no-click-no-keys\n", now - started);
                        fflush(stdout);
                    }
                }
                if (!relocking && inputReady && !shield.protectionIntact) requestRelock(shield.failureReason, NO);
                if (!relocking && guardAt && now - guardAt >= 8) requestRelock(@"input-timeout", NO);
                if (relocking && now - relockAt >= 12) finish(NO, @"relock-unconfirmed-timeout");
            }
            if (!withInput && relockedSince && now - relockedSince >= 3) finish(YES, @"manual-cycle-complete");
            else if (now - started >= 60) finish(NO, @"duration-limit");
        }];
        [NSApp run];
        (void)signalSources; // Retain signal sources through the complete run loop.
        return 4;
    }
}
int MLTransitionTrial(void) { return transitionTrial(NO, NO); }
int MLInputRelockTrial(void) { return transitionTrial(YES, NO); }
int MLTransitionSpaceTrial(void) { return transitionTrial(NO, YES); }

// Separate diagnostic executable; never linked into the installed MacLock app.
int main(int argc, const char *argv[]) {
    signal(SIGPIPE, SIG_IGN);
    if (argc == 3 && strcmp(argv[1], "transition-trial") == 0 && strcmp(argv[2], "--experimental-space") == 0)
        return MLTransitionSpaceTrial();
    if (argc != 2) return 2;
    if (strcmp(argv[1], "guardian-trial") == 0) return MLGuardianTrial();
    if (strcmp(argv[1], "transition-trial") == 0) return MLTransitionTrial();
    if (strcmp(argv[1], "input-relock-trial") == 0) return MLInputRelockTrial();
    return 2;
}
