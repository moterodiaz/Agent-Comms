# agent-coms

Inter-agent message bus over cmux for Claude Code, Codex and Devin running in parallel surfaces. See `SKILL.md` for usage.

    npm i -g agent-coms        # installs bus-register + agent-tell
    npx skills add moterodiaz/agent-coms   # install as an agent skill

State lives in `.agent_bus/` under the git toplevel of the current directory (override with `AGENT_BUS_ROOT`).

Test: `uv run --with pytest pytest tests/ -q`
