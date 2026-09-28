#import <AppKit/AppKit.h>
#import "Runtime.h"

// One separate Guardian owns the only Shield. The coordinator never draws or monitors input.
@interface MLShield : NSObject
@property(nonatomic, copy) void (^onAbort)(NSString *reason);
@property(nonatomic) pid_t companion;
@property(nonatomic) BOOL usesPrivateSpace;
@property(nonatomic) BOOL possibleGrant;
@property(nonatomic) BOOL observedUnlock;
@property(nonatomic) BOOL grantReported;
@property(nonatomic, readonly) BOOL ready;
@property(nonatomic, readonly) BOOL protectionIntact; // Window metadata/input health, not proof of visual coverage.
@property(nonatomic, readonly) BOOL transitionPending;
@property(nonatomic, readonly) BOOL unlockedCoverageVisible;
@property(nonatomic, readonly) BOOL stopping;
@property(nonatomic, readonly) NSUInteger suppressedEvents;
@property(nonatomic, readonly) NSString *failureReason;
- (BOOL)start;
- (BOOL)startInputGuard; // Same guard; trial calls only after manual unlock and a typing grace period.
- (void)coverDisplays; // Shared window construction; does not start input monitoring or authorize anything.
- (void)relockThen:(void (^)(void))completion;
- (BOOL)removeAfterConfirmedLock;
- (void)cancelBeforeGrant;
@end
