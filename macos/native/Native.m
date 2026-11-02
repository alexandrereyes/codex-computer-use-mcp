#import "Shield.h"
#import "Startup.h"
#import "DisplayWake.h"
#include "Attempt.h"
#include <signal.h>
#include <sys/socket.h>
#include <unistd.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <fcntl.h>

static NSString *socketPath(NSString *name) { return [MLInstallRoot stringByAppendingFormat:@"/run/%@.sock", name]; }
static NSString *suppressionPath(void) { return [MLInstallRoot stringByAppendingPathComponent:@"run/suppressed"]; }
static void suppress(void) { [@"until-manual-unlock" writeToFile:suppressionPath() atomically:YES encoding:NSUTF8StringEncoding error:NULL]; }
static double bootTime(void) {
    struct timeval boot; size_t size = sizeof boot; int name[] = {CTL_KERN, KERN_BOOTTIME};
    return sysctl(name, 2, &boot, &size, NULL, 0) == 0 && size == sizeof boot ? boot.tv_sec + boot.tv_usec / 1e6 : 0;
}
static void clearSpentSuppression(BOOL leaseActive) {
    struct stat marker;
    if (lstat(suppressionPath().fileSystemRepresentation, &marker)) return;
    double written = marker.st_mtimespec.tv_sec + marker.st_mtimespec.tv_nsec / 1e9;
    if (MLSuppressionSpent(leaseActive, MLScreenLockState() == MLLockUnlocked, written, bootTime()))
        [NSFileManager.defaultManager removeItemAtPath:suppressionPath() error:NULL];
}

@interface MLCoordinator : NSObject {
    MLControllerPolicy _policy;
    MLLease _lease;
    MLAttempt _attempt;
    NSTask *_guardian;
    NSFileHandle *_guardianInput;
    NSPipe *_guardianOutput;
    int _client;
    BOOL _guarded, _guardianReady, _guardianClosed, _readySent, _stopping, _failed, _idleExpired;
    CFAbsoluteTime _started;
    uid_t _uid;
    BOOL _disabled;
    NSUInteger _generation;
    dispatch_semaphore_t _commitAck;
    BOOL _commitReady;
    BOOL _grantReported;
    BOOL _guardianVisible;
    NSDictionary *_configuration;
}
- (instancetype)initWithConfig:(NSDictionary *)config;
- (void)acceptLease:(int)fd lease:(MLLease)lease;
- (BOOL)authorize:(pid_t)login generation:(NSUInteger *)generation;
- (dispatch_semaphore_t)prepareAuthorization:(pid_t)login nonce:(NSString *)nonce generation:(NSUInteger *)generation;
- (void)noGrantForGeneration:(NSUInteger)generation;
- (void)grantReportedForGeneration:(NSUInteger)generation;
- (void)stop:(NSString *)reason failure:(BOOL)failure;
- (void)processLeaseCommand;
@end
@implementation MLCoordinator
- (instancetype)initWithConfig:(NSDictionary *)config {
    if (!(self = [super init])) return nil;
    _uid = [config[@"uid"] unsignedIntValue];
    _configuration = config;
    fprintf(stderr, "MacLock coordinator pid=%d persistent=%d experimentalUntil=%.0f\n", getpid(),
        [config[@"persistent"] isEqual:@YES], [config[@"experimentalUntil"] doubleValue]);
    _policy.uid = _uid; _client = -1;
    if (SecRequirementCreateWithString((__bridge CFStringRef)config[@"controllerRequirement"], kSecCSDefaultFlags, &_policy.requirement) != errSecSuccess) return nil;
    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        if (self->_client < 0) { clearSpentSuppression(NO); return; }
        if (self->_stopping) return;
        if (!MLInstallationEnabled(self->_configuration, NSDate.date.timeIntervalSince1970)) { [self stop:@"installation-disabled-or-expired" failure:YES]; return; }
        if (!MLGraphicalSessionActive()) { [self stop:@"graphical-session-changed" failure:YES]; return; }
        if (!MLLeaseActive(&self->_lease)) {
            char byte; BOOL eof = recv(self->_client, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0;
            self->_idleExpired = self->_readySent && MLLeaseIdleExpired(&self->_lease);
            [self stop:self->_idleExpired ? @"idle-timeout" : @"lease-ended" failure:!self->_readySent || (!eof && !self->_idleExpired)]; return;
        }
        if (!self->_guarded) {
            if (MLScreenLockState() != MLLockUnlocked) [self stop:@"session-locked-or-unknown-during-call" failure:YES];
            else [self processLeaseCommand];
            return;
        }
        if (!self->_guardian.running) { [self stop:@"guard-lost" failure:YES]; return; }
        if (self->_attempt.phase == MLIdle) {
            if (self->_guardianReady) {
                pid_t login = MLLoginPID();
                if (MLArm(&self->_attempt, MLMonotonicTime(), login, YES, YES)) {
                    fprintf(stderr, "MacLock guard ready; requesting loginwindow Return\n");
                    MLPostReturn(login);
                }
                else [self stop:@"could-not-arm" failure:YES];
            } else if (MLMonotonicTime() - self->_started > 6) [self stop:@"guard-readiness-timeout" failure:YES];
            return;
        }
        if (MLShouldRepeatReturn(&self->_attempt, MLMonotonicTime(), MLLoginPID())) {
            fprintf(stderr, "MacLock attempt still armed; repeating loginwindow Return (password field may have been hidden)\n");
            MLPostReturn(self->_attempt.loginPID);
        }
        if (!self->_readySent && MLMonotonicTime() - self->_started >= 11) { [self stop:@"unlock-or-visible-coverage-timeout" failure:YES]; return; }
        if (MLBeginRunning(&self->_attempt, MLMonotonicTime(), self->_started + 11, MLLeaseActive(&self->_lease),
            self->_grantReported, MLScreenLockState() == MLLockUnlocked, self->_guardianVisible)) {
            fprintf(stderr, "MacLock grant reported; unlock and Guardian visible coverage confirmed\n");
            self->_readySent = YES;
            MLWriteLine(self->_guardianInput.fileDescriptor, @"UNLOCK_OBSERVED");
            MLWriteLine(self->_client, @"READY_SEQUENCE");
        } else if (self->_attempt.phase == MLRunning && MLScreenLockState() != MLLockUnlocked) [self stop:@"session-relocked-or-unknown" failure:YES];
        if (self->_readySent && !self->_stopping) [self processLeaseCommand];
    }];
    return self;
}
- (void)processLeaseCommand {
    char command;
    if (recv(_client, &command, 1, MSG_DONTWAIT) != 1) return;
    if (!MLLeaseCommand(&_lease, command)) { [self stop:@"invalid-or-expired-call-transition" failure:YES]; return; }
    MLWriteLine(_client, command == 'B' ? @"ACTIVE" : @"IDLE");
}
- (void)finishIfCovered {
    if (!_guardianClosed) return;
    fprintf(stderr, "MacLock lease finished guarded=%d result=%s lockState=%ld\n", _guarded, _failed ? "FAILED" : "CLOSED", (long)MLScreenLockState());
    MLWriteLine(_client, _failed ? @"FAILED" : (_idleExpired ? @"IDLE_CLOSED" : @"CLOSED"));
    close(_client); _client = -1; MLRevokeLease(&_lease);
    _guardian = nil; _guardianInput = nil; _guardianOutput = nil;
    _attempt = (MLAttempt){0};
}
- (void)stop:(NSString *)reason failure:(BOOL)failure {
    if (_client < 0 || _stopping) return;
    _stopping = YES; _failed = failure;
    if (_attempt.phase == MLIdle || _attempt.phase == MLArmed) {
        if (_guardian.running) MLWriteLine(_guardianInput.fileDescriptor, @"NO_GRANT");
    }
    MLStop(&_attempt);
    _commitReady = NO;
    if (_commitAck) dispatch_semaphore_signal(_commitAck);
    if (failure) { suppress(); MLWriteLine(_client, [@"ABORT " stringByAppendingString:reason]); }
    if (!_guarded) { _guardianClosed = YES; [self finishIfCovered]; return; }
    if (_guardian.running) {
        @try { [_guardianInput writeData:[@"STOP\n" dataUsingEncoding:NSUTF8StringEncoding]]; }
        @catch (NSException *exception) { (void)exception; }
    } else {
        _failed = YES; _guardianClosed = YES;
        MLPostLock(); // Best effort only: a dead Guardian cannot certify coverage/relock.
        [self finishIfCovered];
    }
}
- (void)acceptLease:(int)fd lease:(MLLease)lease {
    // The first lease of a fresh coordinator arrives before the timer's first check.
    clearSpentSuppression(_client >= 0);
    if (_disabled || _client >= 0 || !MLLeaseActive(&lease) || !MLGraphicalSessionActive() || [NSFileManager.defaultManager fileExistsAtPath:suppressionPath()]) {
        MLWriteLine(fd, @"BUSY_OR_SUPPRESSED"); close(fd); MLRevokeLease(&lease); return;
    }
    if (!MLInstallationEnabled(_configuration, NSDate.date.timeIntervalSince1970)) {
        MLWriteLine(fd, @"FAILED INSTALLATION_DISABLED_OR_EXPIRED"); close(fd); MLRevokeLease(&lease); return;
    }
    MLLockState state = MLScreenLockState();
    if (state == MLLockUnknown) {
        MLWriteLine(fd, @"FAILED LOCK_STATE_UNKNOWN"); close(fd); MLRevokeLease(&lease); return;
    }
    BOOL initiallyLocked = state == MLLockLocked;
    _client = fd; _lease = lease; _attempt = (MLAttempt){0}; ++_generation;
    _stopping = NO; _failed = NO; _readySent = NO; _guardianReady = NO; _idleExpired = NO;
    _commitAck = nil; _commitReady = NO;
    _grantReported = NO;
    _guardianVisible = NO;
    _guardianClosed = NO; _started = MLMonotonicTime();
    _guarded = initiallyLocked;
    if (!_guarded) { _readySent = YES; MLWriteLine(fd, @"READY_SEQUENCE"); return; }
    int channel[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, channel)) { _guarded = NO; [self stop:@"guardian-channel-failed" failure:YES]; return; }
    _guardianInput = [[NSFileHandle alloc] initWithFileDescriptor:channel[0] closeOnDealloc:YES];
    NSFileHandle *childInput = [[NSFileHandle alloc] initWithFileDescriptor:channel[1] closeOnDealloc:YES];
    _guardianOutput = [NSPipe pipe];
    _guardian = [NSTask new]; _guardian.executableURL = [NSURL fileURLWithPath:MLExecutable];
    _guardian.arguments = @[@"guardian"];
    _guardian.standardInput = childInput; _guardian.standardOutput = _guardianOutput;
    _guardian.standardError = NSFileHandle.fileHandleWithStandardError;
    __weak MLCoordinator *weak = self;
    NSTask *task = _guardian;
    _guardian.terminationHandler = ^(NSTask *ended) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MLCoordinator *self = weak; if (!self || self->_guardian != ended) return;
            self->_guardianClosed = YES;
            if (ended.terminationReason != NSTaskTerminationReasonExit || ended.terminationStatus != 0) self->_failed = YES;
            if (self->_stopping) [self finishIfCovered]; else [self stop:@"guardian-exited" failure:YES];
        });
    };
    if (![_guardian launchAndReturnError:NULL]) { _guarded = NO; [self stop:@"guardian-start-failed" failure:YES]; return; }
    [childInput closeFile];
    NSFileHandle *output = _guardianOutput.fileHandleForReading;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *line;
        while ((line = MLReadLine(output.fileDescriptor))) {
            NSString *message = line;
            dispatch_async(dispatch_get_main_queue(), ^{
                MLCoordinator *self = weak; if (!self || self->_guardian != task) return;
                if (self->_stopping) return;
                if ([message isEqual:@"READY"] && MLLeaseActive(&self->_lease)) {
                    self->_guardianReady = YES;
                } else if ([message isEqual:@"UNLOCK_VISIBLE"] && MLLeaseActive(&self->_lease)) {
                    self->_guardianVisible = YES;
                } else if ([message isEqual:@"COMMIT_READY"] && self->_commitAck) {
                    self->_commitReady = YES; dispatch_semaphore_signal(self->_commitAck);
                } else [self stop:[@"guardian:" stringByAppendingString:message] failure:YES];
            });
        }
    });
}
- (dispatch_semaphore_t)prepareAuthorization:(pid_t)login nonce:(NSString *)nonce generation:(NSUInteger *)generation {
    if (!MLInstallationEnabled(_configuration, NSDate.date.timeIntervalSince1970)) return nil;
    if (_client < 0 || _stopping || !_guarded || !_guardianReady || !_guardian.running ||
        !MLGraphicalSessionActive() || MLScreenLockState() != MLLockLocked || login != MLLoginPID() ||
        _attempt.phase != MLArmed || !MLLeaseActive(&_lease)) return nil;
    // The single Guardian must acknowledge possible in-flight Allow before consumption.
    _commitAck = dispatch_semaphore_create(0); _commitReady = NO;
    if (!MLWriteLine(_guardianInput.fileDescriptor, [@"POSSIBLE_GRANT " stringByAppendingString:nonce])) {
        [self stop:@"guardian-channel-lost" failure:YES]; return nil;
    }
    *generation = _generation;
    return _commitAck;
}
- (BOOL)authorize:(pid_t)login generation:(NSUInteger *)generation {
    if (!MLInstallationEnabled(_configuration, NSDate.date.timeIntervalSince1970)) return NO;
    if (!_commitReady || _client < 0 || _stopping || !_guardian.running ||
        !MLGraphicalSessionActive() || MLScreenLockState() != MLLockLocked || login != MLLoginPID()) return NO;
    if (!MLConsume(&_attempt, MLMonotonicTime(), login, MLLeaseActive(&_lease), YES)) {
        [self noGrantForGeneration:_generation]; return NO;
    }
    *generation = _generation;
    return YES;
}
- (void)noGrantForGeneration:(NSUInteger)generation {
    if (_client < 0 || generation != _generation) return;
    if (_guardian.running) MLWriteLine(_guardianInput.fileDescriptor, @"NO_GRANT");
    [self stop:@"authorization-denied" failure:YES];
}
- (void)grantReportedForGeneration:(NSUInteger)generation {
    if (_client >= 0 && generation == _generation) {
        _grantReported = YES;
        if (_guardian.running) MLWriteLine(_guardianInput.fileDescriptor, @"GRANT_CONFIRMED");
    }
}
- (MLControllerPolicy)policy { return _policy; }
- (BOOL)pause { _disabled = YES; return _client < 0; }
@end

static void retireGuardian(MLShield *shield, IOPMAssertionID display) {
    if ([shield removeAfterConfirmedLock]) { MLReleaseDisplay(&display); exit(0); }
    [shield relockThen:^{ retireGuardian(shield, display); }];
}
static int guardianMain(void) {
    if (isatty(STDIN_FILENO) || MLScreenLockState() != MLLockLocked) return 2;
    SecRequirementRef parentRequirement = MLCopyNativeRequirement();
    BOOL trustedParent = parentRequirement && MLPeerMatches(STDIN_FILENO, parentRequirement);
    if (parentRequirement) CFRelease(parentRequirement);
    if (!trustedParent) return 3;
    // Survive termination of the coordinator's process group.
    if (setsid() < 0 && getpgrp() == getpgid(getppid())) return 3;
    IOPMAssertionID display;
    NSString *wakeFailure = MLPrepareLockedDisplay(STDIN_FILENO, &display);
    if (wakeFailure) { MLWriteLine(STDOUT_FILENO, [@"FAILED " stringByAppendingString:wakeFailure]); return 3; }
    MLShield *shield = [MLShield new]; shield.companion = getppid();
    shield.usesPrivateSpace = YES;
    __block BOOL stopping = NO;
    void (^stop)(NSString *) = ^(NSString *reason) {
        if (stopping) return; stopping = YES;
        if (reason) { suppress(); MLWriteLine(STDOUT_FILENO, [@"ABORT " stringByAppendingString:reason]); }
        [shield relockThen:^{ retireGuardian(shield, display); }];
    };
    shield.onAbort = stop;
    if (![shield start]) {
        MLWriteLine(STDOUT_FILENO, [@"FAILED " stringByAppendingString:shield.failureReason]);
        [shield cancelBeforeGrant]; MLReleaseDisplay(&display); return 3;
    }
    __block BOOL announced = NO, visibleAnnounced = NO;
    double started = MLMonotonicTime();
    [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        if (stopping) return;
        BOOL ready = shield.ready;
        if (!announced && ready) { announced = YES; MLWriteLine(STDOUT_FILENO, @"READY"); }
        else if ((announced && !ready && !shield.transitionPending) || (!announced && MLMonotonicTime() - started > 3))
            stop([@"guardian-coverage-or-tap-lost:" stringByAppendingString:shield.failureReason]);
        if (!stopping && announced && ready && shield.unlockedCoverageVisible && !visibleAnnounced) {
            visibleAnnounced = YES;
            MLWriteLine(STDOUT_FILENO, @"UNLOCK_VISIBLE"); // Confirmation on the existing Guardian pipe, before client READY.
        }
        if (!stopping && shield.possibleGrant && !visibleAnnounced && MLMonotonicTime() - started >= 8)
            stop(@"transition-visibility-timeout");
    }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *line;
        while ((line = MLReadLine(STDIN_FILENO))) {
            NSString *message = line;
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([message hasPrefix:@"POSSIBLE_GRANT "]) {
                    if (stopping || !shield.ready) MLWriteLine(STDOUT_FILENO, @"COMMIT_REJECTED");
                    else {
                        shield.possibleGrant = YES; MLWriteLine(STDOUT_FILENO, @"COMMIT_READY");
                    }
                }
                else if ([message isEqual:@"NO_GRANT"]) shield.possibleGrant = NO;
                else if ([message isEqual:@"GRANT_CONFIRMED"]) shield.grantReported = YES;
                else if ([message isEqual:@"UNLOCK_OBSERVED"] && (!shield.possibleGrant || shield.grantReported)) shield.observedUnlock = YES;
                else stop([message isEqual:@"STOP"] ? nil : @"invalid-coordinator-message");
            });
        }
        dispatch_async(dispatch_get_main_queue(), ^{ stop(@"coordinator-lost"); });
    });
    [NSApp run]; MLReleaseDisplay(&display); return 0;
}
static int clientMain(NSDictionary *config, BOOL autoStart) {
    SecRequirementRef requirement = MLCopyNativeRequirement();
    if (!requirement) return 3;
    if (autoStart) {
        // Authenticate this backend descendant before it may launch a GUI coordinator.
        MLControllerPolicy policy = {.uid = getuid()};
        int pair[2]; MLLease proof;
        if (SecRequirementCreateWithString((__bridge CFStringRef)config[@"controllerRequirement"], kSecCSDefaultFlags, &policy.requirement) != errSecSuccess ||
            socketpair(AF_UNIX, SOCK_STREAM, 0, pair)) {
            if (policy.requirement) CFRelease(policy.requirement);
            CFRelease(requirement); return 3;
        }
        BOOL authorized = MLBeginLease(pair[0], &policy, 3, &proof);
        if (authorized) MLRevokeLease(&proof);
        CFRelease(policy.requirement); close(pair[0]); close(pair[1]);
        if (!authorized) { CFRelease(requirement); MLWriteLine(STDOUT_FILENO, @"FAILED CONTROLLER_NOT_AUTHORIZED"); return 3; }
    }
    int fd = autoStart ? MLConnectOrStart(socketPath(@"control"), [MLInstallRoot stringByAppendingPathComponent:@"coordinator.lock"],
        MLExecutable, [MLInstallRoot stringByAppendingPathComponent:@"run/native.log"], requirement, STDIN_FILENO, 3) : MLConnect(socketPath(@"control"));
    BOOL valid = fd >= 0 && requirement && MLPeerMatches(fd, requirement);
    if (requirement) CFRelease(requirement);
    if (!valid) { if (fd >= 0) close(fd); MLWriteLine(STDOUT_FILENO, @"FAILED COORDINATOR_UNAVAILABLE"); return 3; }
    struct timeval timeout = {.tv_sec = 15}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    if (!MLWriteLine(fd, @"SEQUENCE")) { close(fd); return 4; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char byte;
        while (read(STDIN_FILENO, &byte, 1) > 0) {
            if (write(fd, &byte, 1) != 1) break; // Real begin/end only; coordinator validates and acknowledges.
        }
        shutdown(fd, SHUT_WR); // Cancellation during guard startup must revoke too.
    });
    NSString *first = MLReadLine(fd);
    BOOL failed = ![first isEqual:@"READY_SEQUENCE"];
    if (failed && ![first hasPrefix:@"ABORT "]) {
        MLWriteLine(STDOUT_FILENO, [@"FAILED " stringByAppendingString:first ?: @"service-unavailable"]);
        close(fd); return 4;
    }
    MLWriteLine(STDOUT_FILENO, first);
    if (failed) shutdown(fd, SHUT_WR); // Still drain the confirmed cleanup reply.
    timeout.tv_sec = 130; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    NSString *line;
    while ((line = MLReadLine(fd))) {
        if ([line isEqual:@"CLOSED"]) { close(fd); return failed ? 5 : 0; }
        if ([line isEqual:@"IDLE_CLOSED"]) { MLWriteLine(STDOUT_FILENO, line); close(fd); return failed ? 5 : 0; }
        if ([line isEqual:@"ACTIVE"] || [line isEqual:@"IDLE"]) { MLWriteLine(STDOUT_FILENO, line); continue; }
        MLWriteLine(STDOUT_FILENO, line); failed = YES;
        if ([line isEqual:@"FAILED"]) break;
    }
    close(fd); return 5;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        if (argc != 2) return 2;
        NSDictionary *config = MLReadConfig();
        if (!config) return 3;
        BOOL shutdownRequest = strcmp(argv[1], "shutdown") == 0;
        if ((strcmp(argv[1], "pause") == 0 || shutdownRequest) && getuid() == 0) {
            SecRequirementRef requirement = MLCopyNativeRequirement();
            int status = MLAdminRequest(socketPath(@"control"), requirement, shutdownRequest);
            if (requirement) CFRelease(requirement);
            return status;
        }
        if (getuid() != [config[@"uid"] unsignedIntValue]) return 3;
        if (strcmp(argv[1], "guardian") != 0 && !MLInstallationEnabled(config, NSDate.date.timeIntervalSince1970)) {
            MLWriteLine(STDOUT_FILENO, @"FAILED INSTALLATION_DISABLED_OR_EXPIRED"); return 3;
        }
        if (strcmp(argv[1], "lease") == 0 || strcmp(argv[1], "lease-auto") == 0)
            return clientMain(config, strcmp(argv[1], "lease-auto") == 0);
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        if (strcmp(argv[1], "guardian") == 0) return guardianMain();
        BOOL inherited = strcmp(argv[1], "coordinator-auto") == 0;
        if (strcmp(argv[1], "coordinator") != 0 && !inherited) return 2;
        NSString *lockPath = [MLInstallRoot stringByAppendingPathComponent:@"coordinator.lock"];
        int lockFD = inherited ? STDIN_FILENO : open(lockPath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        struct stat lockInfo, expectedLock;
        if (lockFD < 0 || fstat(lockFD, &lockInfo) || lstat(lockPath.fileSystemRepresentation, &expectedLock) ||
            lockInfo.st_dev != expectedLock.st_dev || lockInfo.st_ino != expectedLock.st_ino ||
            lockInfo.st_uid != 0 || !S_ISREG(lockInfo.st_mode) || flock(lockFD, LOCK_EX | LOCK_NB)) return 3;
        MLCoordinator *coordinator = [[MLCoordinator alloc] initWithConfig:config];
        if (!coordinator) return 3;
        int control = MLListen(socketPath(@"control"), 0600), auth = MLListen(socketPath(@"authorization"), 0666);
        if (control < 0 || auth < 0) return 3;
        SecRequirementRef helper = NULL;
        SecRequirementCreateWithString(CFSTR("identifier \"com.apple.SecurityAgentHelper.arm64\" and anchor apple"), kSecCSDefaultFlags, &helper);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            for (;;) {
                int fd = accept(control, NULL, NULL); if (fd < 0) continue;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    struct timeval timeout = {.tv_sec = 3}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
                    NSString *request = MLReadLine(fd);
                    uid_t uid; gid_t gid;
                    if (([request isEqual:@"PAUSE"] || [request isEqual:@"SHUTDOWN"]) && getpeereid(fd, &uid, &gid) == 0 && uid == 0) {
                        __block BOOL idle;
                        dispatch_sync(dispatch_get_main_queue(), ^{
                            idle = [coordinator pause];
                            if (idle && [request isEqual:@"SHUTDOWN"]) {
                                unlink(socketPath(@"control").fileSystemRepresentation);
                                unlink(socketPath(@"authorization").fileSystemRepresentation);
                                MLWriteLine(fd, @"STOPPING");
                                exit(0); // Peer EOF plus release of the singleton flock confirms exit to remove.
                            }
                        });
                        MLWriteLine(fd, idle ? @"IDLE" : @"ACTIVE"); close(fd); return;
                    }
                    MLLease lease; MLControllerPolicy policy = [coordinator policy];
                    if (![request isEqual:@"SEQUENCE"] || !MLBeginLease(fd, &policy, 30, &lease)) { close(fd); return; }
                    dispatch_async(dispatch_get_main_queue(), ^{ [coordinator acceptLease:fd lease:lease]; });
                });
            }
        });
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            for (;;) {
                int fd = accept(auth, NULL, NULL); if (fd < 0) continue;
                struct timeval timeout = {.tv_sec = 2}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
                if (!MLPeerMatches(fd, helper)) { close(fd); continue; }
                NSString *line = MLReadLine(fd);
                int pid = -1; char nonceBytes[37], trailing;
                BOOL syntax = line && sscanf(line.UTF8String, "AUTHORIZE %d %36s%c", &pid, nonceBytes, &trailing) == 2;
                NSString *nonce = syntax ? [NSString stringWithUTF8String:nonceBytes] : nil;
                syntax = syntax && [[NSUUID alloc] initWithUUIDString:nonce] != nil;
                __block BOOL allow = NO;
                __block NSUInteger generation = 0;
                __block dispatch_semaphore_t ready = nil;
                if (syntax) dispatch_sync(dispatch_get_main_queue(), ^{ ready = [coordinator prepareAuthorization:pid nonce:nonce generation:&generation]; });
                if (ready && dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0)
                    dispatch_sync(dispatch_get_main_queue(), ^{ allow = [coordinator authorize:pid generation:&generation]; });
                if (ready && !allow) dispatch_sync(dispatch_get_main_queue(), ^{ [coordinator noGrantForGeneration:generation]; });
                BOOL sent = MLWriteLine(fd, allow ? [NSString stringWithFormat:@"ALLOW %u %@", [config[@"uid"] unsignedIntValue], nonce] : @"DENY");
                if (allow && !sent) dispatch_async(dispatch_get_main_queue(), ^{ [coordinator noGrantForGeneration:generation]; });
                timeout.tv_sec = 130; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
                NSString *report = allow ? MLReadLine(fd) : nil;
                if ([report isEqual:@"NO_GRANT"])
                    dispatch_async(dispatch_get_main_queue(), ^{ [coordinator noGrantForGeneration:generation]; });
                else if ([report isEqual:@"GRANT_SENT"])
                    dispatch_async(dispatch_get_main_queue(), ^{ [coordinator grantReportedForGeneration:generation]; });
                close(fd);
            }
        });
        [NSApp run];
    }
    return 0;
}
