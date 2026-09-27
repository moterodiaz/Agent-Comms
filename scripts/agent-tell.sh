#!/bin/sh
# agent-tell.sh - inter-agent message bus over the cmux socket API.
#
# Usage: agent-tell.sh <target> <message>
#   <target>: peer name from .agent_bus/peers, a surface title, a surface
#             ref (surface:N), or a surface UUID.
#
# The target is validated against `cmux tree` before sending (bad targets
# exit non-zero instead of falling back to the focused pane). The message
# is logged to .agent_bus/<target>.log and injected via `cmux send` with a
# trailing Enter so the prompt submits.

set -u

die() { echo "agent-tell: $*" >&2; exit 1; }

if [ $# -ne 2 ]; then
  echo "usage: $(basename "$0") <target> <message>" >&2
  exit 2
fi

TARGET=$1
MSG=$2

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUS_DIR="$ROOT/.agent_bus"
PEERS="$BUS_DIR/peers"
mkdir -p "$BUS_DIR"

command -v cmux >/dev/null 2>&1 || die "cmux CLI not found in PATH"
TREE=$(cmux --id-format both tree 2>/dev/null) || die "cannot reach cmux socket (is the app running?)"

ref_for_uuid() {
  printf '%s\n' "$TREE" | grep -i "surface surface:.*$1" | grep -o 'surface:[0-9][0-9]*' | head -n 1
}

case $TARGET in
  surface:*)
    REF=$TARGET ;;
  ????????-????-????-????-????????????)
    REF=$(ref_for_uuid "$TARGET") ;;
  *)
    REF=$(sed 's/#.*//' "$PEERS" 2>/dev/null | awk -v n="$TARGET" '$1 == n { print $2; exit }')
    if [ -z "${REF:-}" ]; then
      REF=$(printf '%s\n' "$TREE" | grep 'surface surface:' | grep -F "\"$TARGET\"" | grep -o 'surface:[0-9][0-9]*' | head -n 1)
    fi
    ;;
esac

case ${REF:-} in
  ????????-????-????-????-????????????) REF=$(ref_for_uuid "$REF") ;;
esac

[ -n "${REF:-}" ] || die "unknown target '$TARGET' - add it to .agent_bus/peers or find it with: cmux tree"
printf '%s\n' "$TREE" | grep 'surface surface:' | grep -qw "$REF" \
  || die "target '$TARGET' resolved to '$REF', which is not a live surface - stale .agent_bus/peers? run: cmux tree"

LOG_TARGET=$(printf '%s' "$TARGET" | tr '/ ' '__')
printf '%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${CMUX_SURFACE_ID:-unknown}" "$REF" "$MSG" \
  >> "$BUS_DIR/$LOG_TARGET.log" || die "cannot write $BUS_DIR/$LOG_TARGET.log"

cmux send --surface "$REF" -- "$MSG\n" || die "cmux send to $REF failed"
printf 'sent to %s (%s); logged in %s\n' "$TARGET" "$REF" "$BUS_DIR/$LOG_TARGET.log"
