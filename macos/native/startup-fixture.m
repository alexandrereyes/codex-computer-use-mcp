#import "Startup.h"
#include <assert.h>
#include <sys/socket.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        assert(argc == 2 && getenv("ML_TEST_ROOT"));
        NSString *root = @(getenv("ML_TEST_ROOT"));
        NSString *socket = [root stringByAppendingPathComponent:@"control.sock"];
        NSString *lock = [root stringByAppendingPathComponent:@"coordinator.lock"];
        if (!strcmp(argv[1], "coordinator-auto")) {
            struct stat inherited, expected;
            assert(!fstat(0, &inherited) && !stat(lock.fileSystemRepresentation, &expected));
            assert(inherited.st_ino == expected.st_ino && flock(0, LOCK_EX | LOCK_NB) == 0);
            FILE *starts = fopen([[root stringByAppendingPathComponent:@"starts"] fileSystemRepresentation], "a");
            assert(starts); fprintf(starts, "%d\n", getpid()); fclose(starts);
            if (getenv("ML_TEST_FAIL")) return 77;
            if (getenv("ML_TEST_DELAY")) usleep(400000);
            int listener = MLListen(socket, 0600); assert(listener >= 0);
            BOOL paused = NO;
            for (;;) {
                int fd = accept(listener, NULL, NULL); if (fd < 0) continue;
                NSString *request = MLReadLine(fd);
                if ([request isEqual:@"PAUSE"]) { paused = YES; MLWriteLine(fd, @"IDLE"); close(fd); continue; }
                if ([request isEqual:@"SHUTDOWN"] && paused) {
                    MLWriteLine(fd, @"STOPPING"); close(fd); close(listener); unlink(socket.fileSystemRepresentation); return 0;
                }
                if ([request isEqual:@"STOP"]) { close(fd); close(listener); unlink(socket.fileSystemRepresentation); return 0; }
                MLWriteLine(fd, [request isEqual:@"HELLO"] ? @"SERVING" : @"REFUSED"); close(fd);
            }
        }
        SecStaticCodeRef code = NULL; SecRequirementRef requirement = NULL;
        NSString *executable = [@(argv[0]) stringByStandardizingPath];
        assert(SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:executable], 0, &code) == errSecSuccess);
        assert(SecCodeCopyDesignatedRequirement(code, 0, &requirement) == errSecSuccess);
        if (!strcmp(argv[1], "pause") || !strcmp(argv[1], "shutdown")) {
            int status = MLAdminRequest(socket, requirement, !strcmp(argv[1], "shutdown"));
            CFRelease(code); CFRelease(requirement); return status;
        }
        int fd = MLConnectOrStart(socket, lock, executable, [root stringByAppendingPathComponent:@"log"], requirement,
            !strcmp(argv[1], "cancel") ? 0 : -1, 2);
        int error = errno;
        CFRelease(code); CFRelease(requirement);
        if (!strcmp(argv[1], "cancel")) { assert(fd < 0 && error == ECANCELED); return 0; }
        if (!strcmp(argv[1], "failure")) { assert(fd < 0); return 0; }
        assert(fd >= 0 && MLWriteLine(fd, @"HELLO") && [MLReadLine(fd) isEqual:@"SERVING"]);
        close(fd); return 0;
    }
}
