(adr-xdg-split)=

# 10. Split the home re-binds by XDG category

Date: 2026-05-14

## Status

Accepted

## Context

The `--tmpfs /root` inversion ({ref}`adr-bwrap-isolation`) is default-deny, but
a strict per-tool allow-list under `$HOME` means every new tool — `helm`
plugins, `kubectl`/`krew`, `cargo`, `npm`, `uv`-managed Pythons — needs a bind
added by hand. That doesn't scale. Loosening it naively risks exposing the
credential stores that also live under `$HOME`.

## Decision

Split the bind-back **by XDG category**:

- `$HOME/.config/` keeps the **strict allow-list** (`gh`, `glab-cli`, and that's
  it) because credentials live there by XDG contract.
- `$HOME/.local/share/` and `$HOME/.cache/` are **bulk-bound** — they are
  data/cache locations (plugin trees, registries, download caches), so
  host-installed tooling just works without per-tool additions. Two sub-dirs
  under `.local/share/` (`applications/`, `claude/`) are tmpfs-masked so Claude
  Code's own URL-handler and versioned-binary writes stay ephemeral.
- `.local/bin/` stays tmpfs except for `uv`, `uvx`, and the relocated real
  `claude`, and is **appended** (not prepended) to PATH so a malicious
  `~/.local/bin/<sysname>` cannot hijack a standard command.

## Consequences

- Because `.config/` keeps the strict allow-list, a credentialed tool that
  follows XDG and stores secrets under `~/.config/<tool>/` stays hidden with no
  allow-list change — the bulk-bind never reaches it.
- The forward-compatible bet is on XDG discipline: a tool that stores
  credentials under `~/.local/share/<tool>/` instead would leak — audit when
  adding such a tool.
- Pre-XDG dotdir credential stores (`.ssh`, `.aws`, `.gnupg`, `.docker`,
  `.kube`, `.azure`) sit directly under `$HOME` and stay masked by the baseline
  inversion; only `.config/`, `.local/share/`, and `.cache/` change polarity.
