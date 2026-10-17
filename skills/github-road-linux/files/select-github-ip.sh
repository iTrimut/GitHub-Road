#!/bin/bash
# select-github-ip.sh -- Linux port of GitHub-Road's "verify + pick best IP" core.
#
# For each managed host:
#   1. test the current DNS-resolved IP
#   2. test every candidate IP (real HTTPS over TLS via curl --resolve)
#   3. rank the IPs that answered HTTP 200 at least once, by (passes desc, avg
#      latency asc), and write the TOP_K of them to the pin file
#   4. if none answered at all, drop the pin for that host (fall back to DNS)
# Several IPs per host are kept on purpose: libpin.so hands them to the client
# as a failover list, which is what makes this usable on an intermittently
# blocked link where any single IP may reset.
# Candidate probes run in parallel with fail-fast, so a 30-minute cron run
# finishes in seconds even when most IPs are dead.
#
# The winning IPs are written to the pin file read by libpin.so, so no root and
# no /etc/hosts edit is required.
#
# Env overrides:
#   GITHUB_ROAD_PIN              pin file path   (default ~/.hermes/github-pin)
#   GITHUB_ROAD_LOG              log path        (default ~/.hermes/github-road.log)
#   GITHUB_ROAD_HOSTS            hosts to manage (default "github.com api.github.com")
#   GITHUB_ROAD_CONNECT_TIMEOUT  curl connect timeout seconds (default 5)
#   GITHUB_ROAD_MAX_TIME         curl max time seconds        (default 10)
#   GITHUB_ROAD_PROBES           probes per candidate (default 5)
#   GITHUB_ROAD_TOP_K            IPs written per host (default 3)
set -u

PIN_FILE="${GITHUB_ROAD_PIN:-$HOME/.hermes/github-pin}"
LOG="${GITHUB_ROAD_LOG:-$HOME/.hermes/github-road.log}"
CONNECT_TIMEOUT="${GITHUB_ROAD_CONNECT_TIMEOUT:-5}"
MAX_TIME="${GITHUB_ROAD_MAX_TIME:-10}"
PROBES="${GITHUB_ROAD_PROBES:-5}"
TOP_K="${GITHUB_ROAD_TOP_K:-3}"
HOSTS="${GITHUB_ROAD_HOSTS:-github.com api.github.com}"
QUIET="${GITHUB_ROAD_QUIET:-0}"

# Candidate pools (GitHub Azure-Asia + US). See SKILL.md for how to refresh.
GITHUB_CANDIDATES="140.82.112.4 20.205.243.169 140.82.114.4 20.205.243.168 140.82.121.4 20.205.243.166 20.205.243.170 20.27.177.113 20.27.177.114 20.27.177.115 20.27.177.116 140.82.112.3 140.82.113.3 140.82.113.4 140.82.114.3 140.82.116.3 140.82.121.3"
API_CANDIDATES="140.82.112.6 140.82.113.6 140.82.114.6 140.82.116.6 140.82.121.6 20.205.243.168 20.205.243.169"

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
log() {
    mkdir -p "$(dirname "$LOG")" 2>/dev/null
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null
}
candidates_for() {
    case "$1" in
        api.github.com) printf '%s\n' "$API_CANDIDATES" ;;
        *)              printf '%s\n' "$GITHUB_CANDIDATES" ;;
    esac
}

# Print "HTTPCODE TIME_TOTAL" for host via a specific IP (direct, proxy ignored).
probe() {
    local host="$1" ip="$2"
    curl -s -o /dev/null --noproxy '*' \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
        --resolve "${host}:443:${ip}" "https://${host}" \
        -w '%{http_code} %{time_total}' 2>/dev/null
}

log "select-github-ip start (pid $$)"
say "[-] selecting GitHub IPs (hosts: $HOSTS, probes/IP: $PROBES, top-K: $TOP_K)"

# Build the (host ip) work list, deduping per host.
PAIRS=""
for host in $HOSTS; do
    dns_ip="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')"
    seen=" "
    for ip in $dns_ip $(candidates_for "$host"); do
        [ -n "$ip" ] || continue
        case "$seen" in *" $ip "*) continue ;; esac
        seen="$seen$ip "
        PAIRS="${PAIRS}${host} ${ip}"$'\n'
    done
done

RESULTS="$(mktemp "${TMPDIR:-/tmp}/gh-road.XXXXXX")"
PIN_TMP="$(mktemp "${TMPDIR:-/tmp}/gh-pin.XXXXXX")"
trap 'rm -f "$RESULTS" "$PIN_TMP" "${PIN_TMP}.final"' EXIT

# Probe all candidates in parallel. Each writes "<host> <ip> <ok> <avg>".
while read -r host ip; do
    [ -n "$host" ] || continue
    (
        ok=0; sum=0
        for ((r = 0; r < PROBES; r++)); do
            read -r code t < <(probe "$host" "$ip")
            [ -n "${code:-}" ] || code=000
            if [ "$code" = "200" ]; then
                ok=$((ok + 1))
                sum=$(awk "BEGIN{print $sum + $t}")
            fi
        done
        if [ "$ok" -gt 0 ]; then
            avg=$(awk "BEGIN{printf \"%.3f\", $sum / $ok}")
        else
            avg="0.000"
        fi
        echo "$host $ip $ok $avg"
    ) >>"$RESULTS" &
done <<<"$PAIRS"
wait

# Report and write the top-K IPs per host.
for host in $HOSTS; do
    while read -r h ip ok avg; do
        [ "$h" = "$host" ] || continue
        say "      $host $ip -> HTTP200 x${ok}/${PROBES} (avg ${avg}s)"
    done <"$RESULTS"

    ranked="$(awk -v h="$host" '$1 == h && $3 >= 1 { print $3, $4, $2 }' "$RESULTS" | sort -k1,1nr -k2,2n)"
    if [ -z "$ranked" ]; then
        say "[!!] $host: no IP answered - falling back to DNS (no pin)"
        log "fail $host: no reachable IP, DNS fallback"
        continue
    fi

    printf '%s\n' "$ranked" | head -n "$TOP_K" | while read -r ok avg ip; do
        [ -n "$ip" ] && printf '%s %s\n' "$host" "$ip" >>"$PIN_TMP"
    done
    kept="$(printf '%s\n' "$ranked" | head -n "$TOP_K" | wc -l)"
    primary="$(printf '%s\n' "$ranked" | head -n 1)"
    pok="$(printf '%s\n' "$primary" | awk '{print $1}')"
    pt="$(printf '%s\n' "$primary" | awk '{print $2}')"
    pip="$(printf '%s\n' "$primary" | awk '{print $3}')"
    say "[OK] $host -> $pip (+$((kept - 1)) failover) [best ${pok}/${PROBES}, avg ${pt}s]"
    log "pick $host -> $(printf '%s\n' "$ranked" | head -n "$TOP_K" | awk '{print $3}' | tr '\n' ' ')(best ${pok}/${PROBES})"
done

{
    printf '# managed by github-road-linux; regenerated by select-github-ip.sh\n'
    printf '# format: <hostname> <ip>   -- consumed by libpin.so (LD_PRELOAD, in order)\n'
    cat "$PIN_TMP"
} >"${PIN_TMP}.final"
mkdir -p "$(dirname "$PIN_FILE")" 2>/dev/null
mv -f "${PIN_TMP}.final" "$PIN_FILE"
say "[-] pin file updated: $PIN_FILE"
log "wrote pin file $PIN_FILE ($(grep -vc '^#' "$PIN_FILE" 2>/dev/null || echo 0) entries)"
