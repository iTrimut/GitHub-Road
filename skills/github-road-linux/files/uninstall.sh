#!/bin/bash
# uninstall.sh -- remove the GitHub-Road Linux hooks (bashrc + crontab).
# Keeps libpin.so and the pin file; delete $HOME/.hermes/github-pin to fully revert.
set -u

MARK="github-road-linux"
BASHRC="$HOME/.bashrc"

if grep -q ">>> ${MARK} >>>" "$BASHRC" 2>/dev/null; then
    sed -i "/# >>> ${MARK} >>>/,/# <<< ${MARK} <<</d" "$BASHRC"
    echo "[uninstall] removed bashrc hook"
else
    echo "[uninstall] no bashrc hook found"
fi

CUR="$(crontab -l 2>/dev/null || true)"
if printf '%s\n' "$CUR" | grep -q ">>> ${MARK} >>>"; then
    printf '%s\n' "$CUR" | sed "/# >>> ${MARK} >>>/,/# <<< ${MARK} <<</d" | grep -v '^[[:space:]]*$' | crontab -
    echo "[uninstall] removed crontab auto-heal"
else
    echo "[uninstall] no crontab entry found"
fi

echo "[uninstall] done. (pin file and libpin.so kept; delete \$HOME/.hermes/github-pin to fully revert)"
