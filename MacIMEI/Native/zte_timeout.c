/* Private Linux supervisor for modem commands. No shell and no dynamic runtime. */
#define _GNU_SOURCE
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define VERSION "zte-timeout 1.0.0"
#define GRACE_NS INT64_C(250000000)
#define REAP_NS INT64_C(2000000000)
#define TICK_NS  INT64_C(10000000)

static volatile sig_atomic_t interruption;

static void interrupted(int signo) {
    if (!interruption) interruption = signo;
}

static int64_t monotonic_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) return -1;
    return (int64_t)ts.tv_sec * INT64_C(1000000000) + ts.tv_nsec;
}

static int status_code(int status) {
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 125;
}

static int seconds_argument(const char *text, unsigned *seconds) {
    unsigned value = 0;
    if (!text || !*text) return -1;
    for (const unsigned char *p = (const unsigned char *)text; *p; ++p) {
        if (*p < '0' || *p > '9' || value > 8640) return -1;
        value = value * 10 + (*p - '0');
        if (value > 86400) return -1;
    }
    if (!value) return -1;
    *seconds = value;
    return 0;
}

static int signal_group(pid_t child, int signo) {
    if (!kill(-child, signo) || errno == ESRCH) return 0;
    return -1;
}

/* Error cleanup must remain bounded even if the monotonic clock is unavailable. */
static void emergency_cleanup(pid_t child) {
    signal_group(child, SIGKILL);
    kill(child, SIGKILL);
    for (unsigned attempt = 0; attempt < 100; ++attempt) {
        pid_t reaped;
        do { reaped = waitpid(-1, NULL, WNOHANG); } while (reaped > 0);
        if (reaped < 0 && errno == ECHILD) return;
        struct timespec pause = { .tv_sec = 0, .tv_nsec = 20000000 };
        nanosleep(&pause, NULL);
    }
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--version")) {
        puts(VERSION);
        return 0;
    }
    unsigned seconds;
    if (argc < 3 || seconds_argument(argv[1], &seconds)) {
        fputs("Usage: zte-timeout SECONDS PROGRAM [ARGS...] (1..86400 seconds)\n", stderr);
        return 125;
    }

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = interrupted;
    sigemptyset(&action.sa_mask);
    const int forwarded[] = {SIGHUP, SIGINT, SIGTERM};
    for (size_t i = 0; i < sizeof(forwarded) / sizeof(forwarded[0]); ++i) {
        if (sigaction(forwarded[i], &action, NULL)) {
            perror("zte-timeout: sigaction");
            return 125;
        }
    }
    sigset_t unblocked;
    sigemptyset(&unblocked);
    for (size_t i = 0; i < sizeof(forwarded) / sizeof(forwarded[0]); ++i)
        sigaddset(&unblocked, forwarded[i]);
    if (sigprocmask(SIG_UNBLOCK, &unblocked, NULL)) {
        perror("zte-timeout: signal mask"); return 125;
    }
    struct sigaction child_action;
    memset(&child_action, 0, sizeof(child_action));
    child_action.sa_handler = SIG_DFL;
    sigemptyset(&child_action.sa_mask);
    if (sigaction(SIGCHLD, &child_action, NULL)) {
        perror("zte-timeout: SIGCHLD"); return 125;
    }
    /* Adopt orphaned grandchildren so a stopped command cannot leave zombies. */
    pid_t caller = getppid();
    if (prctl(PR_SET_CHILD_SUBREAPER, 1) || prctl(PR_SET_PDEATHSIG, SIGTERM)) {
        perror("zte-timeout: prctl");
        return 125;
    }
    if (getppid() != caller) interruption = SIGTERM;
    if (interruption) return 128 + interruption;
    int64_t started = monotonic_ns();
    if (started < 0) { perror("zte-timeout: clock"); return 125; }
    int64_t deadline = started + (int64_t)seconds * INT64_C(1000000000);
    pid_t supervisor = getpid();
    pid_t child = fork();
    if (child < 0) { perror("zte-timeout: fork"); return 125; }
    if (!child) {
        if (getppid() != supervisor) _exit(125);
        if (setpgid(0, 0) || prctl(PR_SET_PDEATHSIG, SIGKILL)) _exit(125);
        if (getppid() != supervisor) _exit(125);
        action.sa_handler = SIG_DFL;
        for (size_t i = 0; i < sizeof(forwarded) / sizeof(forwarded[0]); ++i)
            if (sigaction(forwarded[i], &action, NULL)) _exit(125);
        sigset_t empty;
        sigemptyset(&empty);
        if (sigprocmask(SIG_SETMASK, &empty, NULL)) _exit(125);
        execvp(argv[2], &argv[2]);
        int saved_errno = errno;
        fprintf(stderr, "zte-timeout: cannot execute %s: %s\n", argv[2], strerror(saved_errno));
        _exit(saved_errno == ENOENT ? 127 : 126);
    }
    /* Both sides set the group; EACCES means the child already exec'd. */
    if (setpgid(child, child) && errno != EACCES && errno != ESRCH) {
        int saved_errno = errno;
        emergency_cleanup(child);
        errno = saved_errno; perror("zte-timeout: process group"); return 125;
    }

    enum { RUNNING, NORMAL, TIMED_OUT, INTERRUPTED, INTERNAL } reason = RUNNING;
    int child_done = 0, child_status = 0, killed = 0, no_children = 0, interrupt_code = 0;
    int64_t kill_at = 0, finish_at = 0;
    for (;;) {
        int status;
        pid_t reaped;
        no_children = 0;
        for (;;) {
            reaped = waitpid(-1, &status, WNOHANG);
            if (reaped > 0) {
                if (reaped == child) { child_done = 1; child_status = status; }
                continue;
            }
            if (reaped < 0 && errno == EINTR) continue;
            if (reaped < 0 && errno == ECHILD) no_children = 1;
            else if (reaped < 0) reason = INTERNAL;
            break;
        }
        int64_t now = monotonic_ns();
        if (now < 0) {
            emergency_cleanup(child);
            return 125;
        }
        if (reason == RUNNING || reason == NORMAL) {
            if (interruption) {
                reason = INTERRUPTED; interrupt_code = 128 + interruption;
            } else if (reason == RUNNING && !child_done && now >= deadline) {
                reason = TIMED_OUT;
            } else if (child_done) reason = NORMAL;
        }
        if (reason != RUNNING && !kill_at) {
            int signo = reason == INTERRUPTED ? interruption : SIGTERM;
            if (signal_group(child, signo)) reason = INTERNAL;
            kill_at = now + GRACE_NS;
            finish_at = kill_at + REAP_NS;
        }
        if (reason != RUNNING && child_done && no_children) {
            /* A normal command's remaining descendants are also cleaned up. */
            if (kill(-child, 0) < 0 && errno == ESRCH) break;
        }
        if (kill_at && now >= kill_at && !killed) {
            if (signal_group(child, SIGKILL)) reason = INTERNAL;
            killed = 1;
        }
        if (finish_at && now >= finish_at) {
            fputs("zte-timeout: kernel did not finish process cleanup\n", stderr);
            reason = INTERNAL;
            break;
        }
        struct timespec pause = { .tv_sec = 0, .tv_nsec = TICK_NS };
        while (nanosleep(&pause, &pause) < 0 && errno == EINTR && !interruption) {}
    }
    if (reason == TIMED_OUT) return 124;
    if (reason == INTERRUPTED) return interrupt_code;
    if (reason == INTERNAL || !child_done) return 125;
    return status_code(child_status);
}
