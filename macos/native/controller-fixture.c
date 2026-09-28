#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

// Separate signed executable represents the backend. Its descendant execs the
// differently signed test harness, just as a backend starts a Node/Bun MCP.
int main(int argc, const char *argv[]) {
    assert(argc == 3);
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    snprintf(address.sun_path, sizeof(address.sun_path), "%s", argv[1]);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(fd >= 0 && connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0);
    char byte = 'b'; assert(write(fd, &byte, 1) == 1);
    pid_t proxy = fork(); assert(proxy >= 0);
    if (proxy == 0) {
        close(fd);
        execl(argv[2], argv[2], "--peer", argv[1], NULL);
        _exit(127);
    }
    int status;
    assert(waitpid(proxy, &status, 0) == proxy && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    assert(read(fd, &byte, 1) == 1);
    close(fd);
    return 0;
}
