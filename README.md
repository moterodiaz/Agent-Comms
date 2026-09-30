# Agent-Comms

Inter-agent message bus over cmux for Claude Code, Codex and Devin running in parallel surfaces. See `SKILL.md` for usage.

    npm i -g github:moterodiaz/Agent-Comms   # installs bus-register + agent-tell
    npx skills add moterodiaz/Agent-Comms   # install as an agent skill

State lives in `.agent_bus/` under the git toplevel of the current directory (override with `AGENT_BUS_ROOT`).

Test: `uv run --with pytest pytest tests/ -q`
