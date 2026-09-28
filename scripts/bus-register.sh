#!/bin/sh
# bus-register.sh - announce this surface on the inter-agent bus.
#
# Usage: bus-register.sh <name> [--force]
#        bus-register.sh --list
#        bus-register.sh --prune
#
# Resolves the caller's live surface via `cmux identify --json` (no pane
# naming or manual ref lookup needed) and upserts `name -> surface:N` into
# .agent_bus/peers. Refs are session-scoped, so register once per session /
# after a cmux restart. Entries pointing at dead surfaces are pruned on every
# run (including --list); .agent_bus/peers stays the single source of truth
# for who is live.
#
# Registering a name that is already held by a different live surface is a
# collision and fails; pass --force to take the name over.
#
# All writes to the peers file happen under .agent_bus/peers.lock so
# concurrent registrations from several agents cannot clobber each other.

set -u

die() { echo "bus-register: $*" >&2; exit 1; }

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUS_DIR="$ROOT/.agent_bus"
PEERS="$BUS_DIR/peers"
LOCK="$PEERS.lock"
LOCK_TIMEOUT=${BUS_LOCK_TIMEOUT:-10}
mkdir -p "$BUS_DIR"

MODE=register
FORCE=0
NAME=
for arg in "$@"; do
  case $arg in
    --list) MODE=list ;;
    --prune) MODE=prune ;;
    --force) FORCE=1 ;;
    -*) echo "usage: $(basename "$0") <name> [--force] | --list | --prune" >&2; exit 2 ;;
    *) [ -z "$NAME" ] || { echo "usage: $(basename "$0") <name> [--force] | --list | --prune" >&2; exit 2; }
       NAME=$arg ;;
  esac
done
case $MODE in
  register)
    [ -n "$NAME" ] || { echo "usage: $(basename "$0") <name> [--force] | --list | --prune" >&2; exit 2; }
    case $NAME in
      *[!A-Za-z0-9_-]*) die "invalid name '$NAME' (use letters, digits, - and _)" ;;
    esac ;;
  *)
    [ -z "$NAME" ] && [ $FORCE -eq 0 ] || { echo "usage: $(basename "$0") <name> [--force] | --list | --prune" >&2; exit 2; } ;;
esac

command -v cmux >/dev/null 2>&1 || die "cmux CLI not found in PATH"

# mkdir is atomic on every POSIX filesystem, so it doubles as a portable
# mutex. A lock whose DIRECTORY is older than LOCK_TIMEOUT is assumed stale
# (crashed writer) and broken; a fresh lock is never stolen no matter how
# long we wait. The lock dir holds a pid file so a process only releases a
# lock it actually owns.
lock_stale() {
  mtime=$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null)
  [ -n "$mtime" ] && [ $(( $(date +%s) - mtime )) -ge "$LOCK_TIMEOUT" ]
}

unlock() {
  owner=$(cat "$LOCK/pid" 2>/dev/null)
  [ "$owner" = "$$" ] || return 0
  rm -f "$LOCK/pid" 2>/dev/null
  rmdir "$LOCK" 2>/dev/null
}

lock() {
  until mkdir "$LOCK" 2>/dev/null; do
    if lock_stale; then
      rm -f "$LOCK/pid" 2>/dev/null
      rmdir "$LOCK" 2>/dev/null
      continue
    fi
    sleep 1
  done
  printf '%s\n' "$$" > "$LOCK/pid"
  trap unlock EXIT
  trap 'exit 1' INT TERM HUP
}

# Live surface refs across every workspace and window - agents on the bus do
# not necessarily share the caller's workspace.
live_refs() {
  cmux tree --all 2>/dev/null | grep -o 'surface:[0-9][0-9]*' | sort -u
}

# Resolve the caller's surface ref from `cmux identify --json`. Falls back to
# $CMUX_SURFACE_ID (a UUID) mapped through the tree when identify has no
# caller context.
caller_ref() {
  ident=$(cmux identify --json 2>/dev/null) || return 1
  if command -v jq >/dev/null 2>&1; then
    ref=$(printf '%s\n' "$ident" | jq -r '.caller.surface_ref // empty' 2>/dev/null)
  else
    ref=$(printf '%s\n' "$ident" | tr -d '\n' | sed -n 's/.*"caller"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' \
      | grep -o '"surface_ref"[[:space:]]*:[[:space:]]*"surface:[0-9][0-9]*"' | grep -o 'surface:[0-9][0-9]*' | head -n 1)
  fi
  if [ -z "$ref" ] && [ -n "${CMUX_SURFACE_ID:-}" ]; then
    ref=$(cmux --id-format both tree --all 2>/dev/null | grep -i "surface surface:.*$CMUX_SURFACE_ID" \
      | grep -o 'surface:[0-9][0-9]*' | head -n 1)
  fi
  printf '%s\n' "$ref"
}

# Rewrite the peers file keeping comments, blank lines and entries whose ref
# is still live. Malformed non-comment lines (no ref) are dropped.
prune_peers() {
  [ -f "$PEERS" ] || printf '# name -> live cmux surface ref (auto-maintained by bus-register.sh)\n' > "$PEERS"
  printf '%s\n' "$LIVE" | awk '
    NR == FNR { live[$0] = 1; next }
    /^[[:space:]]*(#|$)/ { print; next }
    NF < 2 { next }
    $2 ~ /^surface:/ && !($2 in live) { next }
    { print }
  ' - "$PEERS" > "$TMP" || die "cannot write $TMP"
  mv "$TMP" "$PEERS" || die "cannot update $PEERS"
}

LIVE=$(live_refs)
[ -n "$LIVE" ] || die "cannot reach cmux socket or no live surfaces (is the app running?)"

if [ "$MODE" = register ]; then
  REF=$(caller_ref) || die "cannot reach cmux socket"
  [ -n "$REF" ] || die "no caller surface - run this from inside a cmux terminal"
  printf '%s\n' "$LIVE" | grep -qx "$REF" || die "caller surface $REF is not in the live tree"
fi

lock
TMP="$PEERS.tmp.$$"
prune_peers

case $MODE in
  list)
    cat "$PEERS"
    exit 0 ;;
  prune)
    exit 0 ;;
esac

CURRENT=$(sed 's/#.*//' "$PEERS" | awk -v n="$NAME" '$1 == n { print $2; exit }')
if [ -n "$CURRENT" ] && [ "$CURRENT" != "$REF" ] && [ $FORCE -eq 0 ]; then
  die "name '$NAME' is already registered to live surface $CURRENT (you are $REF) - pick another name or pass --force"
fi

awk -v n="$NAME" '$1 != n' "$PEERS" > "$TMP" || die "cannot write $TMP"
printf '%s %s\n' "$NAME" "$REF" >> "$TMP"
mv "$TMP" "$PEERS" || die "cannot update $PEERS"

printf 'registered %s as %s; logged in %s\n' "$NAME" "$REF" "$PEERS"
