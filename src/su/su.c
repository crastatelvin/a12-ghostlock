// su.c - A12 su client (KernelSU-compatible CLI).
//
// Speaks to the root daemon on /dev/socket/a12su.  Two shapes:
//   one-shot      su -c "cmd" / su <uid> -c cmd... / su root id
//   persistent    su / su --mount-master / su -c "nsenter ... sh"
//
// A persistent shell is a real /system/bin/sh inside the daemon, so $?,
// cd and shell variables behave exactly like Magisk/KernelSU's su.  stdout
// and stderr travel on separate frames: libsu's job protocol writes its end
// marker to both streams and hangs if they are merged.
//
// Wire format (1-byte type + 4-byte LE length + payload):
//   client -> daemon : 'T' target uid (optional, 4 bytes),
//                      'Z' SELinux context (optional),
//                      'C' command, 'I' shell stdin, 'X' stdin EOF
//   daemon -> client : 'O' stdout, 'E' stderr, 'R' 4-byte exit code,
//                      'D' denial message
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <pwd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define SU_SOCK "/dev/socket/a12su"
#define SHELL_MAGIC "\x01" "A12SHELL"
#define KSU_VER "v3.3.1:KernelSU"
#define KSU_VER_CODE "33001"

static int read_full(int fd, void *b, size_t n) {
  size_t o = 0;
  while (o < n) {
    ssize_t r = read(fd, (char *)b + o, n - o);
    if (r <= 0) return -1;
    o += (size_t)r;
  }
  return 0;
}

static int write_full(int fd, const void *b, size_t n) {
  size_t o = 0;
  while (o < n) {
    ssize_t r = write(fd, (const char *)b + o, n - o);
    if (r <= 0) return -1;
    o += (size_t)r;
  }
  return 0;
}

static int send_frame(int fd, char t, const void *p, uint32_t n) {
  unsigned char h[5];
  h[0] = (unsigned char)t;
  memcpy(h + 1, &n, 4);
  if (write_full(fd, h, 5) != 0) return -1;
  if (n) write_full(fd, p, n);
  return 0;
}

/* Returns 1 on a frame, 0 on clean EOF, -1 on error. */
static int recv_frame(int fd, char *t, char *buf, size_t cap, uint32_t *len) {
  unsigned char h[5];
  size_t o = 0;
  while (o < 5) {
    ssize_t r = read(fd, h + o, 5 - o);
    if (r == 0) return 0;
    if (r < 0) return (errno == EINTR) ? -2 : -1;
    o += (size_t)r;
  }
  uint32_t n = 0;
  memcpy(&n, h + 1, 4);
  if (n > cap) return -1;
  *t = (char)h[0];
  *len = n;
  if (n && read_full(fd, buf, n) != 0) return -1;
  return 1;
}

static int connect_daemon(void) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  struct sockaddr_un sa;
  memset(&sa, 0, sizeof(sa));
  sa.sun_family = AF_UNIX;
  snprintf(sa.sun_path, sizeof(sa.sun_path), "%s", SU_SOCK);
  if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

/* Commands that mean "give me a shell", not "run this once".  Neo Backup
 * asks for `nsenter --mount=/proc/1/ns/mnt sh`; every app already shares
 * the init mount namespace here, so a local shell is equivalent. */
static int wants_shell(const char *c) {
  while (*c == ' ' || *c == '\t') c++;
  if (!strcmp(c, "sh") || !strcmp(c, "bash") || !strcmp(c, "/bin/sh") ||
      !strcmp(c, "/system/bin/sh") || !strcmp(c, "-sh"))
    return 1;
  if (!strncmp(c, "nsenter", 7)) {
    size_t n = strlen(c);
    while (n && (c[n - 1] == ' ' || c[n - 1] == '\t')) n--;
    if (n >= 2 && c[n - 1] == 'h' && c[n - 2] == 's') return 1;
  }
  return 0;
}

/* Resolve a KernelSU user argument: a name or a numeric uid. */
static int resolve_uid(const char *s, int *out) {
  if (!strcmp(s, "root")) { *out = 0; return 0; }
  if (!strcmp(s, "shell")) { *out = 2000; return 0; }
  if (!strcmp(s, "system")) { *out = 1000; return 0; }
  char *end = NULL;
  long v = strtol(s, &end, 10);
  if (end && end != s && *end == 0 && v >= 0 && v < 1000000) {
    *out = (int)v;
    return 0;
  }
  struct passwd *pw = getpwnam(s);
  if (pw) { *out = (int)pw->pw_uid; return 0; }
  return -1;
}

static int run_one_shot(int fd, const char *cmd) {
  if (send_frame(fd, 'C', cmd, (uint32_t)strlen(cmd)) != 0) return 1;
  char buf[8192];
  for (;;) {
    char t = 0;
    uint32_t n = 0;
    int r = recv_frame(fd, &t, buf, sizeof(buf), &n);
    if (r <= 0) return 1;
    if (t == 'O') {
      write_full(1, buf, n);
    } else if (t == 'E') {
      write_full(2, buf, n);
    } else if (t == 'D') {
      write_full(2, buf, n);
      return 1;
    } else if (t == 'R') {
      uint32_t code = 1;
      if (n >= 4) memcpy(&code, buf, 4);
      return (int)code;
    }
  }
}

static int run_shell(int fd) {
  if (send_frame(fd, 'C', SHELL_MAGIC, sizeof(SHELL_MAGIC) - 1) != 0) return 1;
  char buf[8192];
  int stdin_open = 1;
  int got_ready = 0;
  for (;;) {
    struct pollfd pf[2];
    pf[0].fd = fd;
    pf[0].events = POLLIN;
    pf[1].fd = stdin_open ? 0 : -1;
    pf[1].events = POLLIN;
    pf[0].revents = pf[1].revents = 0;
    int pr = poll(pf, 2, -1);
    if (pr < 0) {
      if (errno == EINTR) continue;
      return 1;
    }
    if (stdin_open && (pf[1].revents & (POLLIN | POLLHUP | POLLERR))) {
      ssize_t r = read(0, buf, sizeof(buf));
      if (r > 0) {
        if (send_frame(fd, 'I', buf, (uint32_t)r) != 0) return 1;
      } else {
        send_frame(fd, 'X', NULL, 0);
        stdin_open = 0;
      }
    }
    if (pf[0].revents & (POLLIN | POLLHUP | POLLERR)) {
      char t = 0;
      uint32_t n = 0;
      int r = recv_frame(fd, &t, buf, sizeof(buf), &n);
      if (r <= 0) return 1;
      if (t == 'O') {
        write_full(1, buf, n);
      } else if (t == 'E') {
        write_full(2, buf, n);
      } else if (t == 'D') {
        write_full(2, buf, n);
        return 1;
      } else if (t == 'R') {
        /* the first 'R' means "shell is up"; the next one is the exit code */
        if (!got_ready) {
          got_ready = 1;
        } else if (n >= 4) {
          uint32_t code = 1;
          memcpy(&code, buf, 4);
          return (int)code;
        }
      }
    }
  }
}

static void usage(void) {
  fputs(
      "KernelSU\n"
      "\n"
      "Usage: su [options] [-] [user [argument...]] [--] [command]\n"
      "\n"
      "Options:\n"
      "  -c, --command COMMAND        pass COMMAND to the invoked shell\n"
      "  -h, --help                   display this help message and exit\n"
      "  -l, --login                  pretend the shell to be a login shell\n"
      "  -p, --preserve-environment   preserve the entire environment\n"
      "  -s, --shell SHELL            use SHELL instead of /system/bin/sh\n"
      "  -v, --version                display version number and exit\n"
      "  -V                           display version code and exit\n"
      "  -M, --mount-master           force the global mount namespace\n"
      "  -g, --group GROUP            specify the primary group\n"
      "  -G, --supp-group GROUP       specify a supplementary group\n"
      "  -W, --no-wrapper             don't use the ksu fd wrapper\n"
      "      --ksu-no-new-privs       block privilege re-escalation\n"
      "  -Z, --context CONTEXT        specify the SELinux context\n",
      stdout);
}

int main(int argc, char **argv) {
  static char cbuf[8192];
  static char pos[8192];
  const char *cmd = NULL;
  const char *ctx = NULL;
  int target = -1;
  size_t po = 0;
  pos[0] = 0;

  for (int i = 1; i < argc; i++) {
    const char *a = argv[i];
    if (!strcmp(a, "--")) {
      for (i++; i < argc; i++) {
        size_t l = strlen(argv[i]);
        if (po + l + 2 < sizeof(pos)) {
          if (po) pos[po++] = ' ';
          memcpy(pos + po, argv[i], l);
          po += l;
          pos[po] = 0;
        }
      }
      break;
    }
    if (a[0] == '-' && a[1]) {
      if (!strcmp(a, "-h") || !strcmp(a, "--help")) {
        usage();
        return 0;
      }
      if (!strcmp(a, "-v") || !strcmp(a, "--version")) {
        puts(KSU_VER);
        return 0;
      }
      if (!strcmp(a, "-V")) {
        puts(KSU_VER_CODE);
        return 0;
      }
      if (!strcmp(a, "-c") || !strcmp(a, "--command")) {
        /* Magisk/libsu put the command in the remaining argv entries:
         * `su 10012 -c keystore_cli_v2 list` means "keystore_cli_v2 list".
         * KernelSU documents -c as the last option, so joining is safe. */
        size_t co = 0;
        cbuf[0] = 0;
        for (int j = i + 1; j < argc; j++) {
          size_t l = strlen(argv[j]);
          if (co + l + 2 < sizeof(cbuf)) {
            if (co) cbuf[co++] = ' ';
            memcpy(cbuf + co, argv[j], l);
            co += l;
            cbuf[co] = 0;
          }
        }
        cmd = cbuf;
        break;
      }
      if (!strncmp(a, "--command=", 10)) {
        snprintf(cbuf, sizeof(cbuf), "%s", a + 10);
        cmd = cbuf;
        break;
      }
      if (!strcmp(a, "-u") || !strcmp(a, "--user")) {
        if (i + 1 >= argc) { fprintf(stderr, "su: %s needs a user\n", a); return 1; }
        if (resolve_uid(argv[++i], &target) != 0) {
          fprintf(stderr, "su: unknown user: %s\n", argv[i]);
          return 1;
        }
        continue;
      }
      if (!strncmp(a, "--user=", 7)) {
        if (resolve_uid(a + 7, &target) != 0) {
          fprintf(stderr, "su: unknown user: %s\n", a + 7);
          return 1;
        }
        continue;
      }
      if (!strcmp(a, "-Z") || !strcmp(a, "--context") || !strcmp(a, "-z") ||
          !strcmp(a, "-cn")) {
        if (i + 1 >= argc) { fprintf(stderr, "su: %s needs a context\n", a); return 1; }
        ctx = argv[++i];
        continue;
      }
      if (!strncmp(a, "--context=", 10)) { ctx = a + 10; continue; }
      /* Flags that need an argument but that this root cannot enforce.  They
       * are consumed so scripts do not choke on them. */
      if (!strcmp(a, "-s") || !strcmp(a, "--shell") || !strcmp(a, "-g") ||
          !strcmp(a, "--group") || !strcmp(a, "-G") || !strcmp(a, "--supp-group")) {
        i++;
        continue;
      }
      if (!strncmp(a, "--shell=", 8) || !strncmp(a, "--group=", 8) ||
          !strncmp(a, "--supp-group=", 13))
        continue;
      if (!strcmp(a, "-l") || !strcmp(a, "--login") || !strcmp(a, "-p") ||
          !strcmp(a, "--preserve-environment") || !strcmp(a, "-M") ||
          !strcmp(a, "-mm") || !strcmp(a, "--mount-master") || !strcmp(a, "-W") ||
          !strcmp(a, "--no-wrapper") || !strcmp(a, "--ksu-no-new-privs") ||
          !strcmp(a, "-n"))
        continue;
      fprintf(stderr, "su: unknown option: %s\n", a);
      usage();
      return 1;
    }

    /* Free argument: the first one is the target user, the rest form the
     * command when -c was not used (e.g. `su root id`). */
    int uid = -1;
    if (target < 0 && resolve_uid(a, &uid) == 0) {
      target = uid;
      continue;
    }
    size_t l = strlen(a);
    if (po + l + 2 < sizeof(pos)) {
      if (po) pos[po++] = ' ';
      memcpy(pos + po, a, l);
      po += l;
      pos[po] = 0;
    }
  }
  if (!cmd && po) cmd = pos;

  int fd = connect_daemon();
  if (fd < 0) {
    fprintf(stderr, "su: connect %s: %s\n", SU_SOCK, strerror(errno));
    return 1;
  }

  if (ctx && *ctx) {
    if (send_frame(fd, 'Z', ctx, (uint32_t)strlen(ctx)) != 0) { close(fd); return 1; }
  }
  if (target > 0) {
    uint32_t tu = (uint32_t)target;
    if (send_frame(fd, 'T', &tu, 4) != 0) { close(fd); return 1; }
  }

  int rc;
  if (cmd == NULL || wants_shell(cmd)) {
    rc = run_shell(fd);
  } else {
    rc = run_one_shot(fd, cmd);
  }
  close(fd);
  return rc;
}
