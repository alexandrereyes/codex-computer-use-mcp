#ifndef ML_ATTEMPT_H
#define ML_ATTEMPT_H
#include <stdbool.h>
typedef enum { MLIdle, MLArmed, MLConsumed, MLRunning, MLStopping } MLPhase;
typedef struct { MLPhase phase; double deadline; int loginPID; } MLAttempt;
// Called only on the coordinator's serial main queue. A consumed attempt is never rearmed.
bool MLArm(MLAttempt *attempt, double now, int loginPID, bool lease, bool coverage);
bool MLConsume(MLAttempt *attempt, double now, int loginPID, bool lease, bool coverage);
bool MLBeginRunning(MLAttempt *attempt, double now, double deadline, bool lease, bool grantReported, bool unlocked, bool guardianVisible);
void MLStop(MLAttempt *attempt);
bool MLCanReleaseGuard(bool possibleGrant, bool grantReported, bool observedUnlock, bool locked, bool settled, bool loginCoverage);
#endif
