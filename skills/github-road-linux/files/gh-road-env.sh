#!/bin/bash
# gh-road-env.sh -- activate GitHub-Road pinning in the CURRENT shell.
#   source files/gh-road-env.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GITHUB_ROAD_PIN="${GITHUB_ROAD_PIN:-$HOME/.hermes/github-pin}"
export LD_PRELOAD="$HERE/libpin.so${LD_PRELOAD:+:$LD_PRELOAD}"
echo "[gh-road] active  LD_PRELOAD=$LD_PRELOAD  pin=$GITHUB_ROAD_PIN"
