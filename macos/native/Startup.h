#import "Runtime.h"
// Reuse a verified coordinator or transfer its existing singleton flock to a child.
int MLConnectOrStart(NSString *socket, NSString *lock, NSString *executable, NSString *log,
    SecRequirementRef requirement, int cancelFD, double timeout);
int MLAdminRequest(NSString *socket, SecRequirementRef requirement, BOOL shutdownRequest);
