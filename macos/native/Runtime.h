#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <ApplicationServices/ApplicationServices.h>
#include "Controller.h"

extern NSString *const MLInstallRoot;
extern NSString *const MLExecutable;
extern NSString *const MLRight;
NSDictionary *MLReadConfig(void);
BOOL MLInstallationEnabled(NSDictionary *config, NSTimeInterval now);
typedef NS_ENUM(NSInteger, MLLockState) { MLLockUnknown = -1, MLLockUnlocked = 0, MLLockLocked = 1 };
MLLockState MLSessionLockState(NSDictionary *session);
MLLockState MLScreenLockState(void);
BOOL MLLoginUIShown(void);
BOOL MLCoverageQualified(MLLockState state, BOOL loginVisible, BOOL overlayVisible);
typedef NS_ENUM(NSInteger, MLCoverageObservation) { MLCoverageFailed, MLCoveragePending, MLCoveragePrepared, MLCoverageVisible };
MLCoverageObservation MLObserveCoverage(MLLockState state, BOOL loginVisible, BOOL overlayVisible, BOOL possibleGrant, BOOL previouslyVisible);
BOOL MLGraphicalSessionActive(void);
double MLMonotonicTime(void);
pid_t MLLoginPID(void);
BOOL MLCodeMatches(pid_t pid, NSString *requirement);
BOOL MLPeerMatches(int fd, SecRequirementRef requirement);
SecRequirementRef MLCopyNativeRequirement(void);
int MLConnect(NSString *socketPath);
int MLListen(NSString *socketPath, mode_t mode);
NSString *MLReadLine(int fd);
BOOL MLWriteLine(int fd, NSString *line);
void MLPostReturn(pid_t pid);
void MLPostLock(void);
