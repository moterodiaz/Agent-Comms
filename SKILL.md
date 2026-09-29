---
name: agent-coms
description: Use when multiple AI agents (Claude Code, Codex, Devin) run in parallel cmux surfaces and need to find each other, send messages, or hand off specs/files. Provides `bus-register` and `agent-tell`.
---

# Inter-Agent Bus (cmux)

Agents in parallel cmux surfaces share a local message bus stored in `.agent_bus/` at the project root (git toplevel, or `$AGENT_BUS_ROOT`). Add `.agent_bus/` to the project's `.gitignore`.

Install: `npm i -g agent-coms` (or `npx skills add moterodiaz/agent-coms`).

## Join the bus
At session start, announce yourself. Names are self-declared; the surface ref is auto-resolved via `cmux identify`.

    bus-register <your-name>

Pick a stable, descriptive name (e.g. `repo-builder`, `ci-builder`, `devin`). Re-register after a cmux restart or if your surface was reopened; dead entries are pruned on every run. A name held by another live surface is rejected (`--force` takes it over). See who's on the bus:

    bus-register --list

## Send a message

    agent-tell <peer-name> "<message>"

The target is validated before sending (bad target exits non-zero, nothing injected). The message is logged to `.agent_bus/<target>.log`, injected via `cmux send`, then submitted with a discrete `cmux send-key enter`.

## Interrupt a peer

    cmux send-key --surface <surface-ref> ctrl+c

## Heavy payloads (> 2 sentences)
Don't paste specs or code into the terminal. A message over ~500 chars or containing a newline is saved to `.agent_bus/handoff_<timestamp>.md` and only a pointer is sent. To hand off an existing file:

    agent-tell repo-builder @docs/some-spec.md
