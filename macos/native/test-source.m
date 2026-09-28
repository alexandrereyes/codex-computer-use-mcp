#import "Shield.h"
#include <assert.h>
#include <unistd.h>

// Exercise the real source cache without starting AppKit, a tap, or any producer.
// Only process identity/signature lookup is simulated at its runtime boundary.
@interface MLShield (SourceTest)
- (void)rememberSource:(pid_t)pid;
- (BOOL)knownSource:(pid_t)pid;
@end
static uint64_t generation = 1;
static BOOL signedService = YES;
static unsigned checks;
bool MLCaptureController(pid_t pid, MLController *out) {
    *out = (MLController){pid, getuid(), generation, 0}; return pid > 1;
}
BOOL MLCodeMatches(pid_t pid, NSString *requirement) {
    assert([requirement containsString:@"com.openai.sky.CUAService"]);
    assert([requirement containsString:@"2DC432GLL2"]);
    ++checks; return pid == 200 && signedService;
}
MLLockState MLScreenLockState(void) { assert(!"Unexpected GUI state read"); return MLLockUnknown; }
BOOL MLLoginUIShown(void) { assert(!"Unexpected login UI state read"); return NO; }
BOOL MLGraphicalSessionActive(void) { return NO; }
double MLMonotonicTime(void) { return 0; }
pid_t MLLoginPID(void) { return -1; }
void MLPostLock(void) { assert(!"Must never request lock in this test"); }
BOOL MLCoverageQualified(MLLockState state, BOOL login, BOOL overlay) { (void)state; (void)login; (void)overlay; return NO; }
MLCoverageObservation MLObserveCoverage(MLLockState state, BOOL login, BOOL overlay, BOOL grant, BOOL visible) {
    (void)state; (void)login; (void)overlay; (void)grant; (void)visible; return MLCoverageFailed;
}

int main(void) {
    @autoreleasepool {
        MLShield *shield = [MLShield new];
        [shield setValue:[NSMutableDictionary dictionary] forKey:@"syntheticSources"];
        [shield rememberSource:100]; // Existing coordinator Return exemption.
        assert([shield knownSource:100] && checks == 0);
        assert([shield knownSource:200] && checks == 1); // Official producer starts late.
        assert([shield knownSource:200] && checks == 1); // Same live identity is cached.
        generation = 2; signedService = NO;
        assert(![shield knownSource:200] && checks == 2); // PID reuse cannot inherit trust.
        signedService = YES;
        assert([shield knownSource:200] && checks == 3); // Signed restart is revalidated.
        assert(![shield knownSource:201]); // Unrecognized local producer is not exempt.
        assert(![shield knownSource:0]);
        puts("PASS: coordinator source, late official source, cache and signed restart; unsigned identity rejected (runtime identity fixtures).");
        return 0;
    }
}
