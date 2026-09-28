#include "Controller.h"
#include <Security/Security.h>
#include <bsm/libbsm.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <math.h>
#include <string.h>
#include <sys/proc.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static bool info(pid_t pid, struct proc_bsdinfo *out) {
    return pid > 1 && proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, out, sizeof(*out)) == sizeof(*out) && out->pbi_status != SZOMB;
}
bool MLCaptureController(pid_t pid, MLController *controller) {
    struct proc_bsdinfo p;
    if (!info(pid, &p)) return false;
    *controller = (MLController){pid, p.pbi_uid, p.pbi_start_tvsec, p.pbi_start_tvusec};
    return true;
}
static bool same(const MLController *a, const MLController *b) {
    return a->pid == b->pid && a->uid == b->uid && a->startSeconds == b->startSeconds &&
        a->startMicroseconds == b->startMicroseconds;
}
static bool liveAuditToken(audit_token_t token) {
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)&token, sizeof(token));
    const void *keys[] = {kSecGuestAttributeAudit};
    const void *values[] = {data};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecCodeRef code = NULL;
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code);
    if (code) CFRelease(code);
    CFRelease(attributes);
    CFRelease(data);
    // This binds a kernel audit token to its live process execution. It is NOT an
    // OpenAI Team ID check or a claim that an arbitrary signed binary is authorized.
    return status == errSecSuccess;
}
static bool signedController(pid_t pid, SecRequirementRef requirement) {
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    const void *keys[] = {kSecGuestAttributePid}, *values[] = {number};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecCodeRef code = NULL;
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code);
    if (status == errSecSuccess) status = SecCodeCheckValidity(code, kSecCSStrictValidate, requirement);
    if (code) CFRelease(code);
    CFRelease(attributes); CFRelease(number);
    return status == errSecSuccess;
}
static bool authenticatePeer(int fd, const MLControllerPolicy *policy, const MLController *pinned, MLController *controller) {
    audit_token_t token;
    socklen_t length = sizeof(token);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) != 0 || length != sizeof(token) ||
        audit_token_to_euid(token) != policy->uid || !liveAuditToken(token)) return false;
    MLController current, peerBefore, peerAfter;
    pid_t peer = audit_token_to_pid(token);
    if (!MLCaptureController(peer, &peerBefore)) return false;
    pid_t pid = peer;
    struct proc_bsdinfo child, parent;
    bool descendant = false;
    for (unsigned depth = 0; depth < 64 && info(pid, &child); ++depth) {
        if (child.pbi_uid != policy->uid) break;
        if ((!pinned || pinned->pid == pid) && MLCaptureController(pid, controller) &&
            (!pinned || same(pinned, controller)) && signedController(pid, policy->requirement)) {
            descendant = true;
            break;
        }
        if (pinned && pid == pinned->pid) break;
        if (!info((pid_t)child.pbi_ppid, &parent)) break;
        // A PID recycled after its purported child was born cannot be its parent.
        if (parent.pbi_start_tvsec > child.pbi_start_tvsec ||
            (parent.pbi_start_tvsec == child.pbi_start_tvsec && parent.pbi_start_tvusec > child.pbi_start_tvusec)) break;
        pid = (pid_t)child.pbi_ppid;
    }
    return descendant && MLCaptureController(peer, &peerAfter) && same(&peerBefore, &peerAfter) &&
        MLCaptureController(controller->pid, &current) && same(&current, controller) && liveAuditToken(token);
}
static double now(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1e9;
}
bool MLBeginLease(int fd, const MLControllerPolicy *policy, double maxSeconds, MLLease *lease) {
    MLController controller;
    if (!policy->requirement || !isfinite(maxSeconds) || maxSeconds <= 0 || maxSeconds > 120 ||
        !authenticatePeer(fd, policy, NULL, &controller)) return false;
    int ownedFD = fcntl(fd, F_DUPFD_CLOEXEC, 0);
    if (ownedFD < 0) return false;
    *lease = (MLLease){ownedFD, controller, now() + maxSeconds, (SecRequirementRef)CFRetain(policy->requirement), false};
    return true;
}
bool MLLeaseActive(const MLLease *lease) {
    MLController controller;
    MLControllerPolicy policy = {lease->controller.uid, lease->requirement};
    if (lease->fd < 0 || now() >= lease->deadline ||
        !authenticatePeer(lease->fd, &policy, &lease->controller, &controller)) return false;
    char byte;
    ssize_t count = recv(lease->fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT);
    // The coordinator consumes bounded B/I commands; EOF still revokes immediately.
    return (count > 0 || (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) && now() < lease->deadline;
}
bool MLLeaseCommand(MLLease *lease, char command) {
    if (!MLLeaseActive(lease)) return false;
    if (command == 'B' && !lease->callActive) { lease->callActive = true; lease->deadline = now() + 120; return true; }
    if (command == 'I' && lease->callActive) { lease->callActive = false; lease->deadline = now() + 30; return true; }
    return false; // Repeated B cannot extend an active call; repeated I cannot keep idle alive.
}
bool MLLeaseIdleExpired(const MLLease *lease) { return !lease->callActive && now() >= lease->deadline; }
void MLRevokeLease(MLLease *lease) {
    if (lease->fd >= 0) close(lease->fd);
    lease->fd = -1;
    if (lease->requirement) CFRelease(lease->requirement);
    lease->requirement = NULL;
}
