#import "Runtime.h"
#include <assert.h>
#include <string.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--inspect") == 0) {
            NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
            id flag = session[@"CGSSessionScreenIsLocked"];
            printf("sessionAvailable=%d flagPresent=%d flag=%s lockState=%ld (-1=unknown,0=unlocked,1=locked)\n",
                session != nil, flag != nil, flag ? [[flag description] UTF8String] : "absent",
                (long)MLSessionLockState(session));
            return 0;
        }
        if (argc != 1) return 2;
        assert(MLSessionLockState(@{}) == MLLockUnlocked);
        assert(MLSessionLockState(@{@"CGSSessionScreenIsLocked": @YES}) == MLLockLocked);
        assert(MLSessionLockState(@{@"CGSSessionScreenIsLocked": @NO}) == MLLockUnlocked);
        assert(MLSessionLockState(nil) == MLLockUnknown);
        puts("lock-state: absent flag, YES, NO, unavailable session passed");
        assert(MLInstallationEnabled(@{@"experimentalUntil": @600}, 599));
        assert(!MLInstallationEnabled(@{@"experimentalUntil": @600}, 600));
        assert(MLInstallationEnabled(@{@"persistent": @YES}, 1000000));
        NSDictionary *disabled = @{@"persistent": @YES, @"disabled": @YES};
        assert(!MLInstallationEnabled(disabled, 1000000));
        assert(!MLInstallationEnabled(@{}, 1000000));
        puts("installation: experimental deadline, persistent opt-in and administrative disable passed");
        assert(MLCoverageQualified(MLLockLocked, YES, NO)); // Prepared below secure loginwindow.
        assert(MLCoverageQualified(MLLockLocked, NO, YES)); // UI hid before lock flag changed; overlay already visible.
        assert(!MLCoverageQualified(MLLockLocked, NO, NO)); // Neither source confirms protection.
        assert(MLCoverageQualified(MLLockUnlocked, NO, YES));
        assert(!MLCoverageQualified(MLLockUnlocked, YES, NO));
        assert(!MLCoverageQualified(MLLockUnknown, YES, YES));
        puts("coverage-state: prepared locked, visible unlocked, missing coverage and unknown passed");
        assert(MLObserveCoverage(MLLockLocked, YES, NO, NO, NO) == MLCoveragePrepared);
        assert(MLObserveCoverage(MLLockLocked, NO, NO, NO, NO) == MLCoverageFailed); // No pending transition before permit preparation.
        assert(MLObserveCoverage(MLLockLocked, NO, NO, YES, NO) == MLCoveragePending);
        assert(MLObserveCoverage(MLLockUnlocked, NO, NO, YES, NO) == MLCoveragePending); // AppKit observation still delayed.
        assert(MLObserveCoverage(MLLockUnlocked, NO, YES, YES, NO) == MLCoverageVisible);
        assert(MLObserveCoverage(MLLockUnlocked, NO, NO, YES, YES) == MLCoverageFailed); // Loss after confirmation is never pending.
        assert(MLObserveCoverage(MLLockUnknown, YES, YES, YES, NO) == MLCoverageFailed);
        puts("transition: prepared -> pending through unlock -> observed visible; later loss and unknown fail closed");
        return 0;
    }
}
