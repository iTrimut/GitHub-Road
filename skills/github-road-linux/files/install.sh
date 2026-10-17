#!/bin/bash
# install.sh -- install the Linux port of GitHub-Road (NO root required).
#
#   1. builds libpin.so (getaddrinfo shim)
#   2. runs the IP selector once to create the pin file
#   3. adds an idempotent ~/.bashrc hook that activates LD_PRELOAD
#   4. adds an idempotent crontab entry that re-selects IPs every 30 minutes
#
# Safe to re-run. Env overrides: GITHUB_ROAD_PIN, GITHUB_ROAD_LOG.
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN_FILE="${GITHUB_ROAD_PIN:-$HOME/.hermes/github-pin}"
LOG_FILE="${GITHUB_ROAD_LOG:-$HOME/.hermes/github-road.log}"
SELECT="$HERE/select-github-ip.sh"
SO="$HERE/libpin.so"
SRC="$HERE/libpin.c"
BASHRC="$HOME/.bashrc"
MARK="github-road-linux"

log() { printf '[install] %s\n' "$*"; }

command -v gcc  >/dev/null || { echo "ERROR: gcc not found (needed once to build libpin.so)"; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl not found"; exit 1; }

# 1. build the shim -----------------------------------------------------------
log "building libpin.so"
gcc -shared -fPIC -O2 -Wall -o "$SO" "$SRC" -ldl
env LD_PRELOAD="$SO" true >/dev/null 2>&1 || { echo "ERROR: libpin.so sanity check failed"; exit 1; }
log "libpin.so built and sanity-checked"

# 2. initial IP selection -----------------------------------------------------
log "selecting initial GitHub IPs (this probes candidate IPs, ~10-30s)"
GITHUB_ROAD_PIN="$PIN_FILE" GITHUB_ROAD_LOG="$LOG_FILE" bash "$SELECT" || true

# 3. ~/.bashrc hook (idempotent) ---------------------------------------------
if grep -q ">>> ${MARK} >>>" "$BASHRC" 2>/dev/null; then
    log "bashrc hook already present - skipping"
else
    log "adding activation hook to $BASHRC"
    {
        printf '\n# >>> %s >>>\n' "$MARK"
        printf 'if [ -f "%s" ] && [ -f "%s" ]; then\n' "$SO" "$PIN_FILE"
        printf '    export GITHUB_ROAD_PIN="%s"\n' "$PIN_FILE"
        printf '    case ":${LD_PRELOAD:-}:" in\n'
        printf '        *":%s:"*) ;;\n' "$SO"
        printf '        *) export LD_PRELOAD="%s${LD_PRELOAD:+:$LD_PRELOAD}" ;;\n' "$SO"
        printf '    esac\n'
        printf 'fi\n'
        printf '# <<< %s <<<\n' "$MARK"
    } >>"$BASHRC"
fi

# 4. crontab auto-heal (idempotent) ------------------------------------------
CRON_LINE="*/30 * * * * GITHUB_ROAD_PIN=$PIN_FILE GITHUB_ROAD_LOG=$LOG_FILE GITHUB_ROAD_QUIET=1 /bin/bash $SELECT >/dev/null 2>&1"
CUR="$(crontab -l 2>/dev/null || true)"
NEW="$(printf '%s\n' "$CUR" | sed "/# >>> ${MARK} >>>/,/# <<< ${MARK} <<</d" | grep -v '^[[:space:]]*$' || true)"
{
    [ -n "$NEW" ] && printf '%s\n' "$NEW"
    printf '# >>> %s >>>\n' "$MARK"
    printf '%s\n' "$CRON_LINE"
    printf '# <<< %s <<<\n' "$MARK"
} | crontab -
log "crontab auto-heal installed (re-selects IPs every 30 minutes)"

log "done."
log "activate now:  source ~/.bashrc   (or open a new shell)"
log "verify:        env LD_PRELOAD=$SO curl -sI https://github.com | head -1"
[ -f "$PIN_FILE" ] && sed 's/^/[pin] /' "$PIN_FILE"
