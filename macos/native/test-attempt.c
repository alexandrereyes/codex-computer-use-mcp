#include "Attempt.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    MLAttempt a = {0};
    assert(!MLArm(&a, 10, 614, true, false)); // Guard not ready: cannot arm.
    assert(MLArm(&a, 10, 614, true, true));
    assert(!MLConsume(&a, 10.5, 614, false, true)); // Cancelled operation.
    assert(MLConsume(&a, 10.77, 614, true, true));
    assert(!MLConsume(&a, 12.9, 614, true, true)); // Observed second invocation cannot reuse.
    assert(!MLArm(&a, 13, 614, true, true));
    assert(!MLBeginRunning(&a, 13, 18, true, true, true, false)); // Unlock alone never dispatches.
    assert(a.phase == MLConsumed);
    MLAttempt expired = a;
    assert(!MLBeginRunning(&expired, 18, 18, true, true, true, true));
    MLAttempt cancelled = a;
    assert(!MLBeginRunning(&cancelled, 14, 18, false, true, true, true));
    MLStop(&cancelled);
    assert(!MLBeginRunning(&cancelled, 14, 18, true, true, true, true));
    assert(!MLBeginRunning(&a, 14, 18, true, false, true, true));
    assert(MLBeginRunning(&a, 14, 18, true, true, true, true));
    assert(a.phase == MLRunning);
    MLStop(&a);
    assert(!MLConsume(&a, 13, 614, true, true));
    a = (MLAttempt){0};
    assert(MLArm(&a, 20, 614, true, true));
    assert(!MLConsume(&a, 23, 614, true, true));
    puts("PASS: coverage prerequisite, cancellation, single consumption and expiry; second invocation denied.");
    puts("PASS: dispatch waits for Guardian visible confirmation plus grant/unlock; deadline and cancellation never dispatch.");
}
