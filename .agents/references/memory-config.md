# Memory & MCP Configuration

Three config files at the repo root control how AI agents interact with this project's memory and tool systems. Keep them current when the project structure changes significantly.

---

## `mempalace.yaml` — Memory Palace Wing

Defines the `artemis_cluster` wing for the [mempalace MCP server](https://github.com/exikle/mempalace-mcp) (configured globally in `~/.claude.json`). Controls how long-term memories about this project are organized into rooms.

```yaml
wing: artemis_cluster
rooms:
    - name: apps # Deployed apps, HelmRelease configs, per-app issues
    - name: infrastructure # Hardware, networking, storage, Talos
    - name: flux # Flux CD patterns, reconciliation, kustomization issues
    - name: agents # Claude agent setup, skills, memory, MCP config
    - name: general # Miscellaneous cluster context
```

**When to update**: When a major new system is added that doesn't fit an existing room (e.g. adding a new major subsystem with its own distinct knowledge domain). Don't add rooms for individual apps — `apps` covers all of them.

**How mempalace uses it**: The `keywords` arrays in each room guide automatic routing of new memories. When creating a memory via the `mempalace` MCP tool, it routes to the room whose keywords match best.

---

## `entities.json` — Claude Code Entity Recognition

Tells Claude Code which people, projects, and topics are relevant to this repo. Used for entity-aware context and memory routing.

```json
{
  "people": ["Dixon D'Cunha", "exikle"],
  "projects": ["Artemis-Cluster", "Talos", "Flux CD", ...],
  "topics": ["GitOps", "Kubernetes", "HelmRelease", ...]
}
```

**When to update**: When a new major tool or framework is adopted (e.g. adding a new observability stack, a new OIDC provider). Don't add individual app names — only foundational tools and frameworks.

---

## `.claude/mcp.json` — Project MCP Servers

Registers project-specific MCP servers for Claude Code sessions in this repo. These servers are loaded **in addition to** the global servers in `~/.claude.json` (mempalace).

```json
{
    "mcpServers": {
        "litellm-general": {
            "type": "http",
            "url": "https://litellm.dcunha.io/general/mcp",
            "headersHelper": "node /home/exikle/.claude/scripts/litellm-headers.mjs"
        },
        "litellm-media": {
            "type": "http",
            "url": "https://litellm.dcunha.io/media/mcp",
            "headersHelper": "node /home/exikle/.claude/scripts/litellm-headers.mjs"
        },
        "litellm-ops": {
            "type": "http",
            "url": "https://litellm.dcunha.io/ops/mcp",
            "headersHelper": "node /home/exikle/.claude/scripts/litellm-headers.mjs"
        }
    }
}
```

**Tiers and their tools:**

| Tier              | URL                                     | Tools available                             |
| ----------------- | --------------------------------------- | ------------------------------------------- |
| `litellm-general` | `https://litellm.dcunha.io/general/mcp` | SearXNG, Grafana, VictoriaLogs, context7    |
| `litellm-media`   | `https://litellm.dcunha.io/media/mcp`   | Sonarr, Radarr, Prowlarr, Jellyseerr        |
| `litellm-ops`     | `https://litellm.dcunha.io/ops/mcp`     | Kubernetes, GitHub, Forgejo, Home Assistant |

One `litellm` proxy (ToolHive is fully decommissioned), tiers separated by URL path + each `LiteLLMMCPServer`'s `access_groups`. All requests require `Authorization: Bearer <master_key>` (handled by `headersHelper`). `litellm-ops` has privileged cluster access — Claude Code only, not Open WebUI.

**When to update**: When a new MCP server is added or an access_group/tier changes. Proxy config lives in `kubernetes/apps/cortex/litellm/`. Individual MCP servers live in `kubernetes/apps/cortex/mcp/<name>-mcp/`.

---

## Global MCP servers (`~/.claude.json`)

Not in this repo, but always available:

| Server      | Type                                 | Purpose                                                                         |
| ----------- | ------------------------------------ | ------------------------------------------------------------------------------- |
| `mempalace` | stdio (`~/.local/bin/mempalace-mcp`) | Long-term memory organized by this repo's wing; drives session start/stop hooks |
