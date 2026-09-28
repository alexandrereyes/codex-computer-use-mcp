#include "Controller.h"
#include <assert.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

static int connectTo(const struct sockaddr_un *address) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(fd >= 0 && connect(fd, (const struct sockaddr *)address, sizeof(*address)) == 0);
    return fd;
}
static SecRequirementRef fixtureRequirement(void) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL,
        (const UInt8 *)"build/controller-fixture", strlen("build/controller-fixture"), false);
    SecStaticCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    assert(SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code) == errSecSuccess);
    assert(SecStaticCodeCheckValidity(code, kSecCSStrictValidate, NULL) == errSecSuccess);
    assert(SecCodeCopyDesignatedRequirement(code, kSecCSDefaultFlags, &requirement) == errSecSuccess);
    CFRelease(code); CFRelease(url);
    return requirement;
}
int main(int argc, const char *argv[]) {
    alarm(20);
    if (argc == 3 && strcmp(argv[1], "--peer") == 0) {
        // lease-auto authenticates its own ancestry through a kernel socketpair
        // before it may start the coordinator (not just a remote listener peer).
        int pair[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
        MLControllerPolicy policy = {getuid(), fixtureRequirement()};
        MLLease proof;
        assert(MLBeginLease(pair[0], &policy, 3, &proof));
        MLRevokeLease(&proof); CFRelease(policy.requirement);
        close(pair[0]); close(pair[1]);
        struct sockaddr_un address = {.sun_family = AF_UNIX};
        snprintf(address.sun_path, sizeof(address.sun_path), "%s", argv[2]);
        int fd = connectTo(&address);
        char byte = 'p'; assert(write(fd, &byte, 1) == 1 && read(fd, &byte, 1) == 1);
        close(fd); return 0;
    }
    assert(argc == 1);
    char directory[] = "build/controller-test.XXXXXX";
    assert(mkdtemp(directory));
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    assert(snprintf(address.sun_path, sizeof(address.sun_path), "%s/socket", directory) > 0);
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(listener >= 0 && bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0 && listen(listener, 4) == 0);
    // Capture policy ONCE; neither change it nor supply a controller PID on restart.
    MLControllerPolicy policy = {getuid(), fixtureRequirement()};
    int pair[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    MLLease untrusted;
    assert(!MLBeginLease(pair[0], &policy, 3, &untrusted));
    close(pair[0]); close(pair[1]);
    MLLease oldLease = {.fd = -1};
    for (unsigned generation = 0; generation < 2; ++generation) {
        pid_t backend = fork(); assert(backend >= 0);
        if (backend == 0) {
            close(listener);
            execl("build/controller-fixture", "build/controller-fixture", address.sun_path, argv[0], NULL);
            _exit(127);
        }
        char byte;
        int a = accept(listener, NULL, NULL); assert(a >= 0 && read(a, &byte, 1) == 1 && byte == 'b');
        int b = accept(listener, NULL, NULL); assert(b >= 0 && read(b, &byte, 1) == 1 && byte == 'p');
        MLLease backendLease, proxyLease;
        assert(MLBeginLease(a, &policy, 5, &backendLease) && MLLeaseActive(&backendLease));
        assert(MLBeginLease(b, &policy, 5, &proxyLease) && MLLeaseActive(&proxyLease));
        assert(backendLease.controller.pid == backend && proxyLease.controller.pid == backend);
        // Sequence timing is per actual call, not an absolute session lifetime.
        MLLease sequence; assert(MLBeginLease(a, &policy, 30, &sequence));
        double idleDeadline = sequence.deadline;
        assert(MLLeaseCommand(&sequence, 'B') && sequence.callActive);
        assert(sequence.deadline > idleDeadline + 89 && sequence.deadline < idleDeadline + 91);
        double activeDeadline = sequence.deadline;
        assert(!MLLeaseCommand(&sequence, 'B') && sequence.deadline == activeDeadline);
        assert(MLLeaseCommand(&sequence, 'I') && !sequence.callActive);
        assert(sequence.deadline < activeDeadline - 89);
        idleDeadline = sequence.deadline;
        assert(!MLLeaseCommand(&sequence, 'I') && sequence.deadline == idleDeadline);
        assert(!MLLeaseCommand(&sequence, 'X'));
        assert(MLLeaseCommand(&sequence, 'B')); // A second call gets its own 120 seconds.
        sequence.deadline = 0;
        assert(!MLLeaseActive(&sequence) && !MLLeaseIdleExpired(&sequence));
        assert(!MLLeaseCommand(&sequence, 'B') && !MLLeaseCommand(&sequence, 'I'));
        sequence.callActive = false;
        assert(MLLeaseIdleExpired(&sequence)); // Idle expiry is normal cleanup, never active timeout.
        MLRevokeLease(&sequence);
        if (generation == 1) {
            assert(oldLease.controller.pid != backend && !MLLeaseActive(&oldLease));
            MLRevokeLease(&oldLease);
        } else {
            // Same UID as the backend, but different signing identity and no trusted ancestor.
            int sibling = connectTo(&address), c = accept(listener, NULL, NULL); assert(c >= 0);
            MLLease rejected; assert(!MLBeginLease(c, &policy, 5, &rejected));
            close(c); close(sibling);
            MLLease expiring; assert(MLBeginLease(a, &policy, 0.03, &expiring));
            poll(NULL, 0, 50); assert(!MLLeaseActive(&expiring)); MLRevokeLease(&expiring);
            MLLease cancelled; assert(MLBeginLease(a, &policy, 5, &cancelled));
            MLRevokeLease(&cancelled); assert(!MLLeaseActive(&cancelled));
        }
        byte = 'x'; assert(write(b, &byte, 1) == 1);
        for (int i = 0; i < 100 && MLLeaseActive(&proxyLease); ++i) poll(NULL, 0, 5);
        assert(!MLLeaseActive(&proxyLease) && MLLeaseActive(&backendLease));
        assert(kill(backend, SIGKILL) == 0);
        siginfo_t exited;
        assert(waitid(P_PID, (id_t)backend, &exited, WEXITED | WNOWAIT) == 0);
        assert(!MLLeaseActive(&backendLease));
        int status; assert(waitpid(backend, &status, 0) == backend && WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL);
        oldLease = backendLease; // Keep old lease to prove the new instance cannot revive it.
        MLRevokeLease(&proxyLease); close(a); close(b);
    }
    MLRevokeLease(&oldLease); CFRelease(policy.requirement);
    close(listener); unlink(address.sun_path); rmdir(directory);
    puts("PASS: stable signing policy accepted restarted backend + differently signed descendants without enrollment; rejected unrelated same-UID peer; cancellation/expiry/EOF/SIGKILL revoked old leases.");
    return 0;
}
