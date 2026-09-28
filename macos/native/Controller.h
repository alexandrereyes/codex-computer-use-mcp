#ifndef MACLOCK_CONTROLLER_H
#define MACLOCK_CONTROLLER_H
#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>
#include <Security/Security.h>

// Ephemeral identity of the controller execution backing ONE lease.
typedef struct {
    pid_t pid;
    uid_t uid;
    uint64_t startSeconds, startMicroseconds;
} MLController;
bool MLCaptureController(pid_t pid, MLController *controller);
// Persistent local authority: UID and designated signing requirement, supplied by
// trusted bootstrap/configuration, NEVER by the connecting client. Borrowed ref.
typedef struct { uid_t uid; SecRequirementRef requirement; } MLControllerPolicy;

// Owns a CLOEXEC duplicate of fd; caller must MLRevokeLease after a successful begin.
// EOF/cancel/expiry invalidate the lease. The original fd remains the caller's.
// No user credentials, remote identity, Codex thread, or app policy involved.
typedef struct { int fd; MLController controller; double deadline; SecRequirementRef requirement; bool callActive; } MLLease;
bool MLBeginLease(int fd, const MLControllerPolicy *policy, double maxSeconds, MLLease *lease);
bool MLLeaseActive(const MLLease *lease);
// B starts actual work (120 s); I ends it (30 s idle). No periodic heartbeat.
bool MLLeaseCommand(MLLease *lease, char command);
bool MLLeaseIdleExpired(const MLLease *lease);
void MLRevokeLease(MLLease *lease);
#endif
