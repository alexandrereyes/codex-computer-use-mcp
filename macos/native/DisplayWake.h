#import "Runtime.h"
#import <IOKit/pwr_mgt/IOPMLib.h>

// Called only by the authenticated Guardian, before input/coverage/authorization.
// Success returns nil and an assertion owned until confirmed relock/teardown.
NSString *MLPrepareLockedDisplay(int cancellationFD, IOPMAssertionID *displayAssertion);
void MLReleaseDisplay(IOPMAssertionID *assertion);
