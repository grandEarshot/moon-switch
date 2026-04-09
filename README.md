# moon-switch

MoonBit native CLI for switching Codex and Claude providers.

## What It Does

`moon-switch` reads a TOML file containing two provider arrays:

- `[[codex]]`
- `[[claude]]`

When both exist, you first choose the client (`Codex` or `Claude`), then choose
one provider under that client. The tool updates only the matching client
configuration:

- Codex
  - `~/.codex/config.toml`
  - `~/.codex/auth.json`
- Claude
  - `~/.claude/settings.json`

## Usage

```bash
# Use the default config (~/.moon-switch/providers.toml)
moon run cmd/moon-switch --

# Or specify a custom config path
moon run cmd/moon-switch -- --profiles /path/to/providers.toml
```

When running without `--profiles`, the tool looks for
`~/.moon-switch/providers.toml`. If it does not exist, the directory and a
template config file are created automatically.

The repository includes a sanitized example at
[`providers.example.toml`](./providers.example.toml). Keep your real
`providers.toml` out of Git.

## Install

```bash
moon install grandEarshot/moon_switch/cmd/moon-switch@0.1.1
```

This installs the binary as `moon-switch` under `~/.moon/bin/`.

## Interactive Controls

- `↑/↓` or `j/k` moves the cursor
- typing a number jumps to that item
- `b` goes back to client selection when multiple clients exist
- `Enter` confirms the current item
- `0` exits without changing any file

## providers.toml Format

Default location: `~/.moon-switch/providers.toml`

```toml
[[codex]]
name = "OpenAI"
base_url = "https://api.openai.com/v1"
api_key = "sk-..."

[[claude]]
name = "Claude Router"
base_url = "https://example.com/anthropic"
api_key = "token"
ANTHROPIC_MODEL = "claude-sonnet-4-20250514"
```

Rules:

- Top-level root supports `codex` and `claude`
- Both are arrays of tables
- Every item must contain `name`, `base_url`, and `api_key`
- Provider names must be globally unique
- `[[codex]]` items only support those three fields
- In `[[claude]]`, every extra top-level field is written into `settings.json.env`
- Claude extra fields must be strings
- Claude `env` is replaced as a whole on write

## Notes

- Missing target files are created automatically
- `config.toml` is rewritten structurally, comments are not preserved
- Existing provider-specific fields under `model_providers.<name>` are preserved
- Claude root fields such as `permissions` and root `model` are preserved

## Verification

```bash
moon test
```
