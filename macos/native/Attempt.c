#include "Attempt.h"
bool MLArm(MLAttempt *a, double now, int loginPID, bool lease, bool coverage) {
    if (a->phase != MLIdle || loginPID <= 1 || !lease || !coverage) return false;
    *a = (MLAttempt){MLArmed, now + 3, loginPID, 1, now};
    return true;
}
bool MLConsume(MLAttempt *a, double now, int loginPID, bool lease, bool coverage) {
    if (a->phase != MLArmed || now >= a->deadline || a->loginPID != loginPID || !lease || !coverage) return false;
    a->phase = MLConsumed; // Before sending Allow; even a failed reply cannot reuse it.
    return true;
}
void MLStop(MLAttempt *a) { a->phase = MLStopping; }
bool MLShouldRepeatReturn(MLAttempt *a, double now, int loginPID) {
    if (a->phase != MLArmed || now >= a->deadline || a->loginPID != loginPID || a->returns >= 2 || now - a->lastReturn < 0.5)
        return false;
    a->returns++; a->lastReturn = now;
    return true;
}
bool MLBeginRunning(MLAttempt *a, double now, double deadline, bool lease, bool grantReported, bool unlocked, bool guardianVisible) {
    if (a->phase != MLConsumed || now >= deadline || !lease || !grantReported || !unlocked || !guardianVisible) return false;
    a->phase = MLRunning;
    return true;
}
bool MLCanReleaseGuard(bool possibleGrant, bool grantReported, bool observedUnlock, bool locked, bool settled, bool loginCoverage) {
    return (!possibleGrant || (grantReported && observedUnlock)) && locked && settled && loginCoverage;
}
