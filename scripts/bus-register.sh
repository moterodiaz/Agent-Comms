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
LOCK_WAIT=${BUS_LOCK_WAIT_TIMEOUT:-60}
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

# The peers lock is created by a `set -C` (O_EXCL) write: the file and its
# pid content appear in one atomic operation and the claim fails on ANY
# existing target - file or directory - so no window exists where a lock
# lacks a readable owner. A lock is stale only when its owner pid is dead,
# when a
# live pid postdates the lock file (pid recycled - the real creator must
# have started before the file existed), or - for a lock with unreadable
# content (corrupt file, legacy dir lock) - when it is older than
# LOCK_TIMEOUT. A live writer keeps its lock no matter how long it runs;
# waiters give up after LOCK_WAIT seconds and report the holder.
#
# `stat -c` is GNU, `-f` is BSD - `-f` also EXISTS on GNU (filesystem
# status), so try GNU first and numeric-validate; anything ambiguous
# answers "not stale": a missed break costs a wait, a false break costs
# corruption.
mtime_of() {
  m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)
  case $m in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$m"
}

# Epoch seconds when pid $1's process started, for systems without /proc:
# elapsed time from `ps etime` ([[dd-]hh:]mm:ss) subtracted from now.
proc_start() {
  elapsed=$(ps -o etime= -p "$1" 2>/dev/null | awk '{
    sub(/\.[0-9]+$/, ""); d = 0; hms = $0
    if (index(hms, "-")) { split(hms, a, "-"); d = a[1]; hms = a[2] }
    n = split(hms, t, ":"); s = 0
    for (i = 1; i <= n; i++) s = s * 60 + t[i]
    print d * 86400 + s }')
  case $elapsed in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' $(( $(date +%s) - elapsed ))
}

# Owner pid $1 is alive but may be recycled: the process that created the
# lock must have started before the lock file existed. On Linux this is a
# nanosecond -nt test against /proc/<pid>; elsewhere compare ps-derived
# start to the file mtime with a 1s margin for whole-second flooring.
lock_owner_recycled() {
  if [ -d "/proc/$1" ]; then
    [ "/proc/$1" -nt "$2" ]
    return
  fi
  pstart=$(proc_start "$1")
  mtime=$(mtime_of "$2")
  case $pstart in ''|*[!0-9]*) return 1 ;; esac
  case $mtime in ''|*[!0-9]*) return 1 ;; esac
  [ "$pstart" -gt $((mtime + 1)) ]
}

lock_file_stale() {
  owner=$(cat "$1" 2>/dev/null)
  if [ -n "$owner" ]; then
    kill -0 "$owner" 2>/dev/null || return 0
    lock_owner_recycled "$owner" "$1"
    return
  fi
  mtime=$(mtime_of "$1") || return 1
  [ $(( $(date +%s) - mtime )) -ge "$LOCK_TIMEOUT" ]
}

# Atomically claim whatever sits at $LOCK via rename - only one contender
# can move a given incarnation - then re-verify staleness on the claimed
# file. If we accidentally grabbed someone's fresh live lock, put it back
# instead of deleting it.
try_claim_stale() {
  mv "$LOCK" "$LOCK.claim.$$" 2>/dev/null || return 1
  if lock_file_stale "$LOCK.claim.$$"; then
    rm -rf "$LOCK.claim.$$"
    return 0
  fi
  mv -n "$LOCK.claim.$$" "$LOCK" 2>/dev/null
  return 1
}

unlock() {
  owner=$(cat "$LOCK" 2>/dev/null)
  [ "$owner" = "$$" ] && rm -f "$LOCK"
}

lock() {
  trap unlock EXIT
  trap 'exit 1' INT TERM HUP
  waited=0
  until ( set -C; printf '%s\n' "$$" > "$LOCK" ) 2>/dev/null; do
    if lock_file_stale "$LOCK" && try_claim_stale; then
      continue
    fi
    waited=$((waited + 1))
    [ "$waited" -lt "$LOCK_WAIT" ] || die "peers lock held by live pid $(cat "$LOCK" 2>/dev/null || echo unknown) for over ${LOCK_WAIT}s"
    sleep 1
  done
  # Sweep orphaned claim artifacts from earlier contested breaks.
  for stray in "$LOCK".claim.*; do
    [ -e "$stray" ] && lock_file_stale "$stray" && rm -rf "$stray"
  done
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
# is still live. Malformed non-comment lines (no ref) are dropped. The live
# set is re-read here - inside the lock - so a peer that appeared while we
# waited is not pruned as dead; if cmux is briefly unreachable we skip
# pruning rather than wipe the file.
prune_peers() {
  live_now=$(live_refs) || live_now=
  [ -n "$live_now" ] || { echo "bus-register: live tree unreachable - skipping prune" >&2; return 0; }
  [ -f "$PEERS" ] || printf '# name -> live cmux surface ref (auto-maintained by bus-register.sh)\n' > "$PEERS"
  printf '%s\n' "$live_now" | awk '
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
