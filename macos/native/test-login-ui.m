#import "Runtime.h"
#include <notify.h>
#include <assert.h>
#include <string.h>

// Only notify calls are replaced at compile time; exercise the real runtime query.
static uint64_t publishedState;
static uint32_t registerStatus, readStatus;
static unsigned cancellations;
uint32_t notify_register_check(const char *name, int *token) {
    assert(strcmp(name, "com.apple.sessionagent.screenLockUIIsShowing") == 0);
    *token = 7; return registerStatus;
}
uint32_t notify_get_state(int token, uint64_t *state) {
    assert(token == 7); *state = publishedState; return readStatus;
}
uint32_t notify_cancel(int token) {
    assert(token == 7); ++cancellations; return NOTIFY_STATUS_OK;
}
int main(void) {
    @autoreleasepool {
        publishedState = 1;
        assert(MLLoginUIShown() && cancellations == 1);
        publishedState = 0;
        assert(!MLLoginUIShown() && cancellations == 2);
        publishedState = 1; readStatus = NOTIFY_STATUS_FAILED;
        assert(!MLLoginUIShown() && cancellations == 3);
        registerStatus = NOTIFY_STATUS_FAILED;
        assert(!MLLoginUIShown() && cancellations == 3);
        puts("PASS: published secure UI shown/hidden; query failures fail closed; notify token released (isolated fixtures).");
        return 0;
    }
}
