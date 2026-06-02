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

Registers project-specific MCP servers for Claude Code sessions in this repo. These servers are loaded **in addition to** the global servers in `~/.claude.json` (mempalace, mem0).

```json
{
    "mcpServers": {
        "artemis-general": {
            "type": "http",
            "url": "https://mcp-general.dcunha.io"
        },
        "artemis-media": {
            "type": "http",
            "url": "https://mcp-media.dcunha.io"
        },
        "artemis-ops": {
            "type": "http",
            "url": "https://mcp-ops.dcunha.io"
        }
    }
}
```

**Gateways and their tools:**

| Gateway           | URL                             | Tools available                         |
| ----------------- | ------------------------------- | --------------------------------------- |
| `artemis-general` | `https://mcp-general.dcunha.io` | agentmemory, SearXNG, Grafana, context7 |
| `artemis-media`   | `https://mcp-media.dcunha.io`   | Sonarr, Radarr, Prowlarr, Jellyseerr    |
| `artemis-ops`     | `https://mcp-ops.dcunha.io`     | Kubernetes, GitHub, Home Assistant      |

All three are internal-only (LAN via `internal-gateway`). `artemis-ops` has privileged cluster access — Claude Code only, not Open WebUI.

**When to update**: When a new ToolHive gateway is added, renamed, or an existing gateway URL changes, or when MCP servers are added to a gateway group. Gateway configs live in `kubernetes/apps/cortex/toolhive/config/`. Individual MCP servers live in `kubernetes/apps/cortex/mcp/<name>-mcp/`.

---

## Global MCP servers (`~/.claude.json`)

Not in this repo, but always available:

| Server      | Type                                                      | Purpose                                        |
| ----------- | --------------------------------------------------------- | ---------------------------------------------- |
| `mempalace` | stdio (`~/.local/bin/mempalace-mcp`)                      | Long-term memory organized by this repo's wing |
| `mem0`      | SSE (`https://mem0.dcunha.io/mcp/claude-code/sse/exikle`) | Agent memory for cross-session context         |
