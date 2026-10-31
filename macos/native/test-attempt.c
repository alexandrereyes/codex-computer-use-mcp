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
    MLAttempt hidden = {0};
    assert(MLArm(&hidden, 30, 614, true, true)); // The arming Return counts as the first.
    assert(!MLShouldRepeatReturn(&hidden, 30.2, 614)); // Too soon after it.
    assert(!MLShouldRepeatReturn(&hidden, 30.6, 615)); // Another loginwindow.
    assert(MLShouldRepeatReturn(&hidden, 30.6, 614));
    assert(!MLShouldRepeatReturn(&hidden, 31.5, 614)); // At most one repeat.
    assert(MLConsume(&hidden, 31.6, 614, true, true));
    MLAttempt consumed = {0};
    assert(MLArm(&consumed, 40, 614, true, true));
    assert(MLConsume(&consumed, 40.3, 614, true, true));
    assert(!MLShouldRepeatReturn(&consumed, 40.6, 614)); // Authorization already took the attempt.
    MLAttempt late = {0};
    assert(MLArm(&late, 50, 614, true, true));
    assert(!MLShouldRepeatReturn(&late, 53, 614)); // The armed window closed.
    MLAttempt idle = {0};
    assert(!MLShouldRepeatReturn(&idle, 1, 614));
    puts("PASS: coverage prerequisite, cancellation, single consumption and expiry; second invocation denied.");
    puts("PASS: one repeated Return, only while armed for the same loginwindow, at least 0.5 s after the first.");
    puts("PASS: dispatch waits for Guardian visible confirmation plus grant/unlock; deadline and cancellation never dispatch.");
}
