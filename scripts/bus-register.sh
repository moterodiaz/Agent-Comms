#!/bin/sh
# bus-register.sh - announce this surface on the inter-agent bus.
#
# Usage: bus-register.sh <name>
#        bus-register.sh --list
#        bus-register.sh --prune
#
# Resolves the caller's live surface via `cmux identify` (no pane naming or
# manual ref lookup needed) and upserts `name -> surface:N` into
# .agent_bus/peers. Refs are session-scoped, so register once per session /
# after a cmux restart. Entries pointing at dead surfaces are pruned on every
# run; .agent_bus/peers stays the single source of truth for who is live.

set -u

die() { echo "bus-register: $*" >&2; exit 1; }

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUS_DIR="$ROOT/.agent_bus"
PEERS="$BUS_DIR/peers"
mkdir -p "$BUS_DIR"
[ -f "$PEERS" ] || printf '# name -> live cmux surface ref (auto-maintained by bus-register.sh)\n' > "$PEERS"

live_refs() {
  cmux tree 2>/dev/null | grep -o 'surface:[0-9][0-9]*' | sort -u
}

if [ $# -eq 1 ] && [ "$1" = "--list" ]; then
  cat "$PEERS"
  exit 0
fi

command -v cmux >/dev/null 2>&1 || die "cmux CLI not found in PATH"
LIVE=$(live_refs)
[ -n "$LIVE" ] || die "cannot reach cmux socket or no live surfaces (is the app running?)"

# Drop peer lines whose surface ref is no longer in the live tree, plus
# malformed non-comment lines.
if [ -s "$PEERS" ]; then
  while IFS= read -r line; do
    case $line in
      ''|'#'*) printf '%s\n' "$line"; continue ;;
    esac
    ref=$(printf '%s\n' "$line" | awk '{print $2}')
    case $ref in
      surface:*)
        printf '%s\n' "$LIVE" | grep -qx "$ref" && printf '%s\n' "$line" ;;
      '')
        : ;;
      *)
        printf '%s\n' "$line" ;;
    esac
  done < "$PEERS" > "$PEERS.tmp" && mv "$PEERS.tmp" "$PEERS"
fi

if [ $# -eq 1 ] && [ "$1" = "--prune" ]; then
  exit 0
fi

[ $# -eq 1 ] || { echo "usage: $(basename "$0") <name> | --list | --prune" >&2; exit 2; }
NAME=$1
case $NAME in
  ''|*[!A-Za-z0-9_-]*) die "invalid name '$NAME' (use letters, digits, - and _)" ;;
esac

IDENT=$(cmux identify 2>/dev/null) || die "cannot reach cmux socket"
if command -v jq >/dev/null 2>&1; then
  REF=$(printf '%s\n' "$IDENT" | jq -r '.caller.surface_ref // empty')
else
  REF=$(printf '%s\n' "$IDENT" | sed -n '/"caller"/,/}/p' | grep -o '"surface_ref"[^,}]*' | cut -d'"' -f4 | head -n 1)
fi
[ -n "$REF" ] || die "no caller surface - run this from inside a cmux terminal"

grep -v "^$NAME " "$PEERS" > "$PEERS.tmp" 2>/dev/null || true
printf '%s %s\n' "$NAME" "$REF" >> "$PEERS.tmp"
mv "$PEERS.tmp" "$PEERS"

printf 'registered %s as %s; logged in %s\n' "$NAME" "$REF" "$PEERS"
