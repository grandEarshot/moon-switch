# Changelog

## 0.1.2 - 2026-04-10

- Fix Codex config rewriting so `~/.codex/config.toml` keeps only the selected `model_providers` entry.
- Remove stale provider-specific fields and stale provider tables left behind by earlier switches.
- Preserve unrelated Codex config sections such as `projects`, `notice`, `mcp_servers`, and `skills`.
