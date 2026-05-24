# gbrain Integration Plan

## Context

This document captures decisions made in a planning session. The goal is to deploy
[garrytan/gbrain](https://github.com/garrytan/gbrain) as a self-hosted personal
knowledge management (PKM) system, accessible via MCP from any Claude session or
other AI agent.

**Key repos:**
- Cluster config: `gilesknap/tpi-k3s-ansible`
- gbrain: `garrytan/gbrain` (18.6k stars, TypeScript, Bun)

---

## What gbrain is

A self-wiring knowledge graph + hybrid RAG engine that acts as persistent memory
across all agent sessions. Key properties:

- **Markdown + git** as source of truth (brain repo) — Obsidian-compatible mental model
- **Hybrid retrieval**: pgvector HNSW + BM25 + knowledge graph, not vector-only
- **Synthesis with citations and gap analysis** — not raw chunk retrieval
- **MCP-first**: 30+ tools over HTTP MCP, works with Claude Code, Claude Desktop,
  Cursor, and any other MCP client
- **Multi-agent**: multiple agents can read/write concurrently

---

## Decisions made

### 1. Purpose
General-purpose personal PKM — not cluster-specific. All projects, all contexts.
Any agent can contribute or query.

### 2. Replace open-brain-mcp
Replace the existing `open-brain-mcp` deployment entirely. No data migration from
the existing `thoughts` table — clean start.

### 3. Brain repo
A new **private GitHub repo** as the brain repo (markdown files, git-backed).
Survives cluster rebuilds. Fits the existing GitOps ethos.

### 4. Authentication
**gbrain's built-in OAuth 2.1 + PKCE**. Simplest path; works directly with Claude
Code, Cursor, Claude Desktop without additional proxy config. Do NOT wire through
the existing oauth2-proxy/Dex — unnecessary complexity.

### 5. Embeddings
**ollama on nuc2, CPU-only, `nomic-embed-text` model (768-dim).**

Reasoning:
- RK1 NPU (rkllama) is flaky — avoided entirely; ollama uses ARM64/x86 CPU BLAS
- Workstation GPU (ws03) is a gaming machine — NoSchedule taint, do not use
- nuc2 is x86_64 with AVX2, fast CPU BLAS, no GPU contention
- nomic-embed-text is ~137MB, minimal resource footprint
- No external API dependency, no billing

Ollama pod: pin to `nuc2`, CPU-only (set `CUDA_VISIBLE_DEVICES=""`), `nomic-embed-text` pulled on startup.

**Note:** The existing Supabase schema uses 1536-dim vectors (`thoughts` table).
gbrain starts fresh — use **768-dim** to match nomic-embed-text. No schema migration needed.

### 6. Database
**Existing Supabase** (already deployed in the cluster, pgvector enabled). gbrain
runs its own migrations into a new schema — no conflict with the existing `thoughts`
table.

Supabase internal URL: `http://{{ supabase_release_name }}-supabase-kong.supabase.svc.cluster.local:8000`

### 7. External access
**Cloudflare Tunnel** (already deployed as `cloudflared` in the cluster). Expose
gbrain's HTTP MCP endpoint externally so it's reachable from Claude Desktop,
Claude Code on the web, mobile, etc. — not just from within the local network.

Target URL pattern: `https://brain.{{ cluster_domain }}`

### 8. gbrain internal LLM
**Defer / start disabled.** For the core capture+search workflow, Claude (the
client session) does the synthesis — gbrain just does retrieval and storage. The
internal LLM (used for background dream cycle: contradiction detection, citation
fixing, enrichment) is optional to get started.

If/when needed: use OpenRouter or LiteLLM proxy pointed at a Claude model, funded
by the Claude Max API allocation (available from June 2025). Do NOT configure a
separate OpenAI account just for this.

### 9. Deployment pattern
Follow the existing ArgoCD GitOps pattern exactly:
- New `kubernetes-services/additions/gbrain/` helm chart (Chart.yaml, values.yaml, templates/)
- New `kubernetes-services/additions/ollama/` helm chart
- New `kubernetes-services/templates/gbrain.yaml` ArgoCD Application (replacing `open-brain-mcp.yaml`)
- New `kubernetes-services/templates/ollama.yaml` ArgoCD Application
- Values wired via `kubernetes-services/values.yaml` with `enable_gbrain` / `enable_ollama` flags
- Ingress via the existing reusable ingress sub-chart

---

## Cluster topology (for context)

| Node | Hardware | Role | Notes |
|---|---|---|---|
| node01 | CM4 8GB | Control plane | No workloads |
| node02 | RK1 + NVMe | Worker | Available |
| node03 | RK1 + NVMe | Worker | Available |
| node04 | RK1 + NVMe | Worker | rkllama pinned here (NPU) |
| nuc2 | Intel NUC x86_64 | Worker | **ollama target** |
| ws03 | Workstation + NVIDIA | Worker | NoSchedule taint — GPU only, do not use |

---

## What to build (task list)

- [ ] Create private GitHub brain repo
- [ ] `kubernetes-services/additions/ollama/` helm chart
  - Deployment pinned to nuc2, CPU-only, pulls `nomic-embed-text`
  - Service on port 11434
- [ ] `kubernetes-services/additions/gbrain/` helm chart
  - Deployment replacing open-brain-mcp
  - Configured: Supabase URL, brain repo, ollama embedding endpoint, OAuth
  - Service on port 8000
- [ ] `kubernetes-services/templates/ollama.yaml` ArgoCD Application
- [ ] `kubernetes-services/templates/gbrain.yaml` ArgoCD Application (replaces open-brain-mcp.yaml)
- [ ] Set `enable_open_brain_mcp: false` in values.yaml
- [ ] Add `enable_gbrain`, `enable_ollama` flags to values.yaml
- [ ] Supabase: verify pgvector enabled (already is), gbrain will run its own migrations
- [ ] Wire MCP into Claude sessions via `~/.claude/settings.json` mcpServers entry

---

## What NOT to do

- Do not use the RK1 NPU for embeddings (rkllama is flaky, different driver stack)
- Do not use the workstation GPU (gaming machine, NoSchedule taint)
- Do not use Gemini API (Google Cloud billing is opaque, separate account needed)
- Do not use OpenAI embeddings (unnecessary new subscription)
- Do not edit `devcontainer.json` automatically — always print a snippet to paste
- Do not migrate data from the existing `thoughts` table — clean start
- Do not run workloads on node01 (control plane)

---

## Reference: existing open-brain-mcp structure (to mirror)

The existing service follows this pattern — gbrain should match it:

```
kubernetes-services/
  templates/
    open-brain-mcp.yaml        # ArgoCD Application, references two sources:
                               #   1. additions/open-brain-mcp (helm)
                               #   2. additions/ingress (reusable sub-chart)
  additions/
    open-brain-mcp/
      Chart.yaml               # apiVersion: v2, name, version: 0.1.0
      values.yaml              # defaults for standalone helm template
      templates/
        deployment.yaml        # nodeSelector: amd64, envFrom secretRef, /health probe
        service.yaml           # ClusterIP, port 8000
        open-brain-mcp-secret.yaml  # SealedSecret
```

Key patterns to follow:
- `nodeSelector: kubernetes.io/arch: amd64` for x86 workloads
- `envFrom: secretRef` for credentials (use SealedSecrets)
- `/health` liveness + readiness probes
- Ingress via reusable `additions/ingress` sub-chart with `name`, `cluster_domain`, `service_name`, `service_port`
- ArgoCD Application with `automated: prune: true, selfHeal: true` and `CreateNamespace: true`
- `{{- if .Values.enable_X }}` guard in the ArgoCD template
