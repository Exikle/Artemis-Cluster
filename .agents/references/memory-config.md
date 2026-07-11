# Memory & MCP Configuration

How AI agents get tools and long-term memory in this repo. Keep this current when the MCP layout or memory system changes.

---

## `.mcp.json` — Project MCP Servers

Repo-root file registering project-specific MCP servers for Claude Code sessions. Loaded in addition to any global servers configured in `~/.claude.json` or via Claude Code plugins.

```json
{
    "mcpServers": {
        "litellm-general": {
            "type": "http",
            "url": "https://litellm.dcunha.io/general/mcp",
            "headersHelper": "node /home/exikle/.claude/scripts/litellm-headers.mjs"
        },
        "litellm-media": { "...": "same shape, /media/mcp" },
        "litellm-ops": { "...": "same shape, /ops/mcp" }
    }
}
```

**Tiers and their tools:**

| Tier              | URL                                     | Tools available                             |
| ----------------- | --------------------------------------- | ------------------------------------------- |
| `litellm-general` | `https://litellm.dcunha.io/general/mcp` | SearXNG, Grafana, VictoriaLogs, context7    |
| `litellm-media`   | `https://litellm.dcunha.io/media/mcp`   | Sonarr, Radarr, Prowlarr, Jellyseerr        |
| `litellm-ops`     | `https://litellm.dcunha.io/ops/mcp`     | Kubernetes, GitHub, Forgejo, Home Assistant |

One `litellm` proxy, tiers separated by URL path + each `LiteLLMMCPServer`'s `access_groups`. All requests require `Authorization: Bearer <master_key>` (handled by `headersHelper`). `litellm-ops` has privileged cluster access — Claude Code only, not Open WebUI.

Proxy config lives in `kubernetes/apps/cortex/litellm/`. Individual MCP servers live in `kubernetes/apps/cortex/mcp/<name>-mcp/`.

**When to update**: when a new MCP server is added, an `access_group`/tier changes, or a URL moves.

---

## memini — Cross-Session Memory

`memini` is a Claude Code plugin (not registered in `.mcp.json`) providing semantic long-term memory scoped to this project, with tools under `mcp__memini__*`. It replaced the earlier `mempalace` MCP server — there are no `mempalace.yaml` or `entities.json` files in this repo; routing and scoping are handled by the plugin itself, not by repo-local config.

- **Load**: call `memory_recall` / `memory_answer` / `memory_briefing` when starting work on a topic that may have prior history.
- **Save**: call `memory_remember` after a non-obvious discovery — a quirk, a failure mode, a workaround that would take real effort to re-derive.
- **Don't** use memini for conventions, architecture, or project context that's already documented in `.agents/` — that content belongs in an instruction, reference, or skill file instead, where it's version-controlled and reviewable.

The `memini` app itself (embeddings + storage) is deployed in-cluster at `kubernetes/apps/cortex/memini/` — that's the service the plugin talks to, distinct from the plugin/client side described above.

**When to update this doc**: when the memini plugin's scoping model changes, or the in-cluster deployment moves namespace.
