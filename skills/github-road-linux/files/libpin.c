/*
 * libpin.c -- LD_PRELOAD getaddrinfo() shim (non-root alternative to /etc/hosts)
 *
 * Linux port of the "GitHub-Road" hosts-pinning idea. On a machine where the
 * user has no root (cannot edit /etc/hosts), we still need to force specific
 * hostnames (e.g. github.com) to chosen IPs. This shim interposes
 * getaddrinfo() and, for any hostname listed in the pin file, returns the
 * pinned IP(s) *instead of* the DNS answer.
 *
 * Multiple IPs per host are supported and returned as one linked list, so the
 * client (curl / git / anything using libcurl or getaddrinfo) automatically
 * fails over to the next IP when one is reset or blackholed -- essential on
 * flaky, intermittently-blocked links.
 *
 * The pin file is read at call time, so IP changes from the auto-heal cron job
 * take effect immediately, with no recompile.
 *
 * Pin file format (whitespace separated, '#' comments allowed; order matters,
 * first line per host is tried first):
 *     github.com      140.82.112.4
 *     github.com      20.205.243.169
 *     api.github.com  20.205.243.168
 *
 * Pin file location (override with env GITHUB_ROAD_PIN):
 *     $HOME/.hermes/github-pin
 *
 * Build:
 *     gcc -shared -fPIC -O2 -o libpin.so libpin.c -ldl
 *
 * Use:
 *     LD_PRELOAD=/path/to/libpin.so git push ...
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef GITHUB_ROAD_PIN_REL
#define GITHUB_ROAD_PIN_REL ".hermes/github-pin"
#endif
#define MAX_PINS 32

typedef int (*getaddrinfo_fn)(const char *, const char *,
                              const struct addrinfo *, struct addrinfo **);

static getaddrinfo_fn real_ga(void) {
    static getaddrinfo_fn real = NULL;
    if (!real)
        real = (getaddrinfo_fn)dlsym(RTLD_NEXT, "getaddrinfo");
    return real;
}

/* Collect every pinned IP for host, in file order. Returns the count. */
static int collect_pins(const char *host, char out[][64], int max) {
    const char *env = getenv("GITHUB_ROAD_PIN");
    char path[4096];

    if (env && *env) {
        snprintf(path, sizeof(path), "%s", env);
    } else {
        const char *home = getenv("HOME");
        if (!home || !*home)
            return 0;
        snprintf(path, sizeof(path), "%s/%s", home, GITHUB_ROAD_PIN_REL);
    }

    FILE *f = fopen(path, "r");
    if (!f)
        return 0;

    int n = 0;
    char line[1024];
    while (n < max && fgets(line, sizeof(line), f)) {
        char h[256], ip[64];
        char *p = line;
        while (*p == ' ' || *p == '\t')
            p++;
        if (*p == '#' || *p == '\n' || *p == '\0')
            continue;
        if (sscanf(p, "%255s %63s", h, ip) == 2 && strcasecmp(h, host) == 0)
            snprintf(out[n++], 64, "%s", ip);
    }
    fclose(f);
    return n;
}

int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **res) {
    getaddrinfo_fn real = real_ga();
    if (!real)
        return EAI_SYSTEM;

    if (node && *node) {
        char pins[MAX_PINS][64];
        int n = collect_pins(node, pins, MAX_PINS);
        if (n > 0) {
            struct addrinfo *head = NULL, *tail = NULL;
            int i;
            for (i = 0; i < n; i++) {
                struct addrinfo *ai = NULL;
                if (real(pins[i], service, hints, &ai) != 0 || !ai)
                    continue;
                if (!head)
                    head = ai;
                else
                    tail->ai_next = ai;
                tail = ai;
                while (tail->ai_next)
                    tail = tail->ai_next;
            }
            if (head) {
                *res = head;
                return 0;
            }
        }
    }
    return real(node, service, hints, res);
}
