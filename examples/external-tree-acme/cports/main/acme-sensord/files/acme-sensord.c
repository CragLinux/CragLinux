/*
 * acme-sensord — the docs/08 §7 reference app for Astro external trees.
 *
 * A ~200-line "sensor" daemon demonstrating the three platform
 * integrations an app package opts into via its service manifest
 * (files/acme-sensord.toml, docs/08 §5):
 *
 *   data_dir          $ASTRO_DATA_DIR (/data/apps/acme-sensord) exists,
 *                     is owned by the service user, and survives OS
 *                     updates (it lives in /data). The config file is
 *                     kept — and created on first boot — there.
 *
 *   api_client        the 'acme' service user is joined to the
 *                     astro-api group at image assembly, which is what
 *                     authorizes connecting to astrod's unix socket
 *                     (docs/02 §7 — the socket dir is 0750
 *                     astrod:astro-api; there is no token on this
 *                     surface). At startup we GET /api/v1/network and
 *                     /api/v1/update/status and log the results.
 *
 *   api_controllable  POST /api/v1/services/acme-sensord/restart is
 *                     allowed (docs/06 §5.4). Nothing to implement
 *                     in-process — dinit restarts us; we just exit
 *                     cleanly on SIGTERM.
 *
 * $ASTRO_DATA_DIR and $ASTRO_API_SOCKET arrive via the env file
 * /etc/astro/services/acme-sensord.env, generated at image assembly and
 * referenced by the service description's own `env-file =` line.
 *
 * Plain C99 + POSIX, no dependencies beyond libc, cross-built by cbuild
 * against the exact target image (docs/08 §3, AD-017).
 */
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_INTERVAL 30 /* seconds between readings */
#define MIN_INTERVAL 1
#define MAX_INTERVAL 3600
#define STARTUP_TRIES 15  /* seconds to wait for astrod's listener */
#define RESP_CAP 4096     /* keep this much of an API response */
#define BODY_LOG_CAP 300  /* log at most this much response body */

static volatile sig_atomic_t running = 1;

static void handle_term(int sig)
{
    (void)sig;
    running = 0;
}

/* Timestamped line to stdout; the dinit service description points
 * `logfile` at /var/log/acme-sensord.log and captures this. Explicit
 * fflush because a logfile is block-buffered by default. */
static void logline(const char *fmt, ...)
{
    char stamp[32];
    time_t now = time(NULL);
    struct tm tm;
    gmtime_r(&now, &tm);
    strftime(stamp, sizeof stamp, "%Y-%m-%dT%H:%M:%SZ", &tm);

    va_list ap;
    va_start(ap, fmt);
    printf("%s acme-sensord: ", stamp);
    vprintf(fmt, ap);
    putchar('\n');
    va_end(ap);
    fflush(stdout);
}

static const char *env_or(const char *name, const char *fallback)
{
    const char *v = getenv(name);
    return (v && *v) ? v : fallback;
}

/* Config lives in the app data dir ($ASTRO_DATA_DIR/sensord.conf); on
 * first boot the default is written there — which doubles as proof the
 * manifest's data_dir wiring produced a directory we can write. */
static int load_interval(const char *dir)
{
    char path[512];
    snprintf(path, sizeof path, "%s/sensord.conf", dir);

    FILE *f = fopen(path, "r");
    if (!f) {
        f = fopen(path, "w");
        if (!f) {
            logline("cannot create %s (%s); using interval %d", path,
                    strerror(errno), DEFAULT_INTERVAL);
            return DEFAULT_INTERVAL;
        }
        fprintf(f,
                "# acme-sensord configuration. Lives in $ASTRO_DATA_DIR\n"
                "# (docs/08 sec. 5): owned by the service user, kept\n"
                "# across OS updates, wiped by factory reset.\n"
                "interval = %d\n",
                DEFAULT_INTERVAL);
        fclose(f);
        logline("wrote default config %s", path);
        return DEFAULT_INTERVAL;
    }

    int interval = DEFAULT_INTERVAL;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        int v;
        if (sscanf(line, " interval = %d", &v) == 1)
            interval = v;
    }
    fclose(f);

    if (interval < MIN_INTERVAL || interval > MAX_INTERVAL) {
        logline("config interval %d out of range [%d,%d]; using %d",
                interval, MIN_INTERVAL, MAX_INTERVAL, DEFAULT_INTERVAL);
        interval = DEFAULT_INTERVAL;
    }
    logline("config: interval = %d s", interval);
    return interval;
}

/* One GET over the astrod unix socket (the api_client pattern). astrod
 * speaks minimal HTTP/1.1; with Connection: close, "read until EOF" is
 * the whole client. No Host header and no auth token are needed on this
 * surface — group membership already authorized the connect. Returns
 * the HTTP status, or -1 with errno set if astrod is unreachable. */
static int api_get(const char *sock_path, const char *path, char *resp,
                   size_t cap)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof addr.sun_path, "%s", sock_path);

    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }

    char req[256];
    int req_len = snprintf(req, sizeof req,
                           "GET %s HTTP/1.1\r\nConnection: close\r\n\r\n",
                           path);
    ssize_t off = 0;
    while (off < req_len) {
        ssize_t n = write(fd, req + off, (size_t)(req_len - off));
        if (n < 0) {
            close(fd);
            return -1;
        }
        off += n;
    }

    size_t len = 0;
    for (;;) {
        char sink[512];
        char *dst = (len < cap - 1) ? resp + len : sink;
        size_t room = (len < cap - 1) ? cap - 1 - len : sizeof sink;
        ssize_t n = read(fd, dst, room);
        if (n <= 0)
            break;
        if (len < cap - 1)
            len += (size_t)n;
    }
    close(fd);
    resp[len] = '\0';

    int status = 0;
    if (sscanf(resp, "HTTP/%*s %d", &status) != 1 || status <= 0)
        return -1;
    return status;
}

/* Log one endpoint's status + (truncated) body. Non-2xx is expected on
 * some images — e.g. 503 while RAUC is unreachable — and must not kill
 * the daemon: this is telemetry, not a dependency. */
static void probe(const char *sock_path, const char *path)
{
    char resp[RESP_CAP];
    int status = api_get(sock_path, path, resp, sizeof resp);
    if (status < 0) {
        logline("GET %s: astrod unreachable (%s)", path, strerror(errno));
        return;
    }
    const char *body = strstr(resp, "\r\n\r\n");
    body = body ? body + 4 : "";
    logline("GET %s -> %d: %.*s%s", path, status, BODY_LOG_CAP, body,
            strlen(body) > (size_t)BODY_LOG_CAP ? "..." : "");
}

int main(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = handle_term;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    const char *dir = env_or("ASTRO_DATA_DIR", "/data/apps/acme-sensord");
    const char *sock = env_or("ASTRO_API_SOCKET", "/run/astro/astrod.sock");
    logline("starting (data_dir=%s, api_socket=%s)", dir, sock);

    int interval = load_interval(dir);

    /* dinit marks astrod started as soon as its process is up, which can
     * be a beat before the listener binds; retry briefly instead of
     * racing it. If astrod never answers, run without it. */
    int tries = STARTUP_TRIES;
    char resp[RESP_CAP];
    int status = -1;
    while (tries-- > 0 && running) {
        status = api_get(sock, "/api/v1/network", resp, sizeof resp);
        if (status > 0)
            break;
        sleep(1);
    }
    if (status > 0) {
        const char *body = strstr(resp, "\r\n\r\n");
        body = body ? body + 4 : "";
        logline("GET /api/v1/network -> %d: %.*s%s", status, BODY_LOG_CAP,
                body, strlen(body) > (size_t)BODY_LOG_CAP ? "..." : "");
        probe(sock, "/api/v1/update/status");
    } else {
        logline("astrod not reachable after %d s; continuing without it",
                STARTUP_TRIES);
    }

    /* The "sensor": a deterministic fake reading every interval. */
    unsigned long sample = 0;
    int tick = 0;
    while (running) {
        if (tick == 0) {
            double temp_c = 21.0 + 3.0 * (double)(sample % 8) / 8.0;
            logline("reading %lu: temp=%.2f C", sample, temp_c);
            sample++;
        }
        sleep(1);
        tick = (tick + 1) % interval;
    }

    logline("terminating; %lu readings taken", sample);
    return 0;
}
