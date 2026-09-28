#import "Startup.h"
#include <spawn.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <poll.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
extern char **environ;

int MLAdminRequest(NSString *socket, SecRequirementRef requirement, BOOL shutdownRequest) {
    int fd = MLConnect(socket);
    BOOL trusted = fd >= 0 && requirement && MLPeerMatches(fd, requirement);
    NSString *reply = trusted && MLWriteLine(fd, shutdownRequest ? @"SHUTDOWN" : @"PAUSE") ? MLReadLine(fd) : nil;
    char byte;
    BOOL stopped = shutdownRequest && [reply isEqual:@"STOPPING"] && read(fd, &byte, 1) == 0;
    if (fd >= 0) close(fd);
    if (reply) MLWriteLine(STDOUT_FILENO, reply);
    return (shutdownRequest ? stopped : [reply isEqual:@"IDLE"]) ? 0 : 4;
}

int MLConnectOrStart(NSString *socket, NSString *lock, NSString *executable, NSString *log,
    SecRequirementRef requirement, int cancelFD, double timeout) {
    double deadline = MLMonotonicTime() + timeout;
    pid_t child = 0;
    while (MLMonotonicTime() < deadline) {
        struct pollfd cancelled = {.fd = cancelFD, .events = POLLIN | POLLHUP};
        if (cancelFD >= 0 && poll(&cancelled, 1, 0) > 0) { errno = ECANCELED; return -1; }
        int fd = MLConnect(socket);
        if (fd >= 0) {
            if (MLPeerMatches(fd, requirement)) return fd; // LEASE/READY handshake follows on this exact connection.
            close(fd); errno = EACCES; return -1;
        }
        if (errno != ENOENT && errno != ECONNREFUSED) return -1;
        if (child && waitpid(child, NULL, WNOHANG) == child) { errno = ECHILD; return -1; }
        if (!child) {
            int lockFD = open(lock.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
            if (lockFD < 0) return -1;
            if (flock(lockFD, LOCK_EX | LOCK_NB) == 0) {
                posix_spawn_file_actions_t actions;
                posix_spawnattr_t attributes;
                posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes);
                // The same open-file description holds the flock across spawn: no startup race or extra lock file.
                posix_spawn_file_actions_adddup2(&actions, lockFD, STDIN_FILENO);
                posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log.fileSystemRepresentation,
                    O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600);
                posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);
                posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT);
                char *args[] = {(char *)executable.fileSystemRepresentation, "coordinator-auto", NULL};
                int status = posix_spawn(&child, executable.fileSystemRepresentation, &actions, &attributes, args, environ);
                posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes);
                close(lockFD);
                if (status) { errno = status; return -1; }
            } else {
                int error = errno; close(lockFD);
                if (error != EWOULDBLOCK && error != EAGAIN) { errno = error; return -1; }
            }
        }
        // Cancellation abandons this request, never kills the shared coordinator another client may need.
        if (cancelFD >= 0) { struct pollfd p = {.fd = cancelFD, .events = POLLIN | POLLHUP}; poll(&p, 1, 50); }
        else usleep(50000);
    }
    errno = ETIMEDOUT; return -1;
}
