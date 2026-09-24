/* Exact, regular, non-symlink local plan reads; no modem API or mutations. */
#ifndef ZTE_PLAN_IO_H
#define ZTE_PLAN_IO_H
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static int read_exact_plan(const char *path, void *bytes, size_t size) {
    if (!path || path[0] != '/') return 0;
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return 0;
    struct stat before, after;
    int okay = fstat(fd, &before) == 0 && S_ISREG(before.st_mode) &&
        before.st_size == (off_t)size && before.st_nlink == 1;
    size_t offset = 0;
    while (okay && offset < size) {
        ssize_t n = read(fd, (unsigned char *)bytes + offset, size - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { okay = 0; break; }
        offset += (size_t)n;
    }
    unsigned char extra;
    ssize_t n;
    do { n = read(fd, &extra, 1); } while (n < 0 && errno == EINTR);
    okay = okay && n == 0 && fstat(fd, &after) == 0 &&
        after.st_size == before.st_size && after.st_dev == before.st_dev &&
        after.st_ino == before.st_ino && after.st_mtime == before.st_mtime &&
        after.st_ctime == before.st_ctime && after.st_nlink == 1;
    if (close(fd) != 0) okay = 0;
    return okay;
}
#endif
