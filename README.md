# Tavily MCP Manager

A global CLI to manage multiple Tavily API keys and run `tavily-mcp` with switchable keys for AI coding agents.

**Supported agents:** OpenAI Codex · Claude Code · Gemini CLI · OpenCode

## GitHub

📦 **Repository:** [https://github.com/ngmkhoi/tavily-mcp-manager](https://github.com/ngmkhoi/tavily-mcp-manager)

> If you find this tool useful, please consider giving it a ⭐ star on GitHub — it helps others discover the project!

## Install

```bash
npm i -g tavily-mcp-manager
```

## Quick Start

```bash
tavily-manager init
tavily-manager add tvly-... --alias personal
tavily-manager doctor
```

Register the server with your agent:

```bash
tavily-manager mcp install claude     # or codex / gemini / opencode
tavily-manager mcp install all        # every agent found on this machine
tavily-manager mcp install claude --dry-run   # show what would change
tavily-manager mcp install claude --force     # replace an existing entry
```

This writes the config for you, with `TAVILY_AUTO_ROTATE=1` already set. Where
the agent ships its own CLI (`claude`, `codex`, `gemini`) that CLI is used, so
the agent stays the authority on its own config format; otherwise the config
file is patched directly, leaving every unrelated key alone and keeping a
`.bak` copy. Re-running is a no-op, and a config file that does not parse is
left untouched rather than overwritten.

To copy the config in yourself instead:

```bash
tavily-manager mcp config list      # show supported agents
tavily-manager mcp config codex     # Codex TOML
tavily-manager mcp config claude    # Claude Code JSON
tavily-manager mcp config gemini    # Gemini CLI JSON
tavily-manager mcp config opencode  # OpenCode JSON
```

## CLI Commands

| Category | Commands |
|----------|----------|
| **Key setup** | `init`, `add <key> [--alias]`, `list`, `current`, `switch <slot\|alias>` |
| **Key maintenance** | `key add`, `key rename`, `key remove` |
| **Usage & rotation** | `usage [all]`, `rotate [--dry-run]` |
| **Setup** | `mcp install <agent\|all>`, `mcp config <agent>` |
| **Diagnostics** | `doctor`, `mcp status` |

## Multi-Agent MCP Setup

### Codex

```toml
[mcp_servers.tavily]
command = "tavily-mcp-manager"
args = []
```

### Claude Code

Add to `~/.claude.json` or `.mcp.json`:

```json
{
  "mcpServers": {
    "tavily": {
      "command": "tavily-mcp-manager",
      "args": []
    }
  }
}
```

### Gemini CLI

Add to `~/.gemini/settings.json`:

```json
{
  "mcpServers": {
    "tavily": {
      "command": "tavily-mcp-manager",
      "args": []
    }
  }
}
```

### OpenCode

Add to `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "tavily": {
      "type": "local",
      "command": ["tavily-mcp-manager"],
      "enabled": true,
      "environment": {}
    }
  }
}
```

## Auto-Rotation

Enable automatic key rotation before MCP startup:

```bash
TAVILY_AUTO_ROTATE=1 tavily-mcp-manager
```

Or in agent config:

```toml
[mcp_servers.tavily]
command = "tavily-mcp-manager"
args = []
env = { TAVILY_AUTO_ROTATE = "1" }
```

## Config Paths

State lives under `~/.tavily-mcp-manager`:

```
~/.tavily-mcp-manager/keys.env      # API key values
~/.tavily-mcp-manager/config.json   # active key, aliases, metadata
```

### Environment Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `TAVILY_HOME` | `~/.tavily-mcp-manager` | Manager home path |
| `TAVILY_CONFIG_FILE` | — | Metadata config path |
| `TAVILY_KEYS_FILE` | — | Secret key file path |
| `TAVILY_NPM_CACHE` | `$TAVILY_HOME/npm-cache` | npm cache for MCP wrapper |
| `TAVILY_MCP_VERSION` | `0.2.19` | Pinned `tavily-mcp` version |
| `TAVILY_MCP_ALLOW_GLOBAL` | `0` | Set `1` to allow falling back to a global `tavily-mcp` |
| `TAVILY_USAGE_WARNING_PERCENT` | `5` | Low-credit warning threshold |
| `TAVILY_USAGE_STARTUP_CHECK` | `1` | Set `0` to skip startup checks |
| `TAVILY_USAGE_CACHE_TTL_SECONDS` | `300` | Usage cache lifetime; `0` disables |
| `TAVILY_AUTO_ROTATE` | `0` | Set `1` to rotate before startup |
| `TAVILY_ROTATE_THRESHOLD_PERCENT` | — | Min remaining % for auto-rotate |
| `TAVILY_PROJECT_ID` | — | Tavily project header for usage API |

### Why the npm cache is not in /tmp

macOS prunes files under `/tmp` that have not been accessed for a few days.
Directories survive but individual files do not, which leaves a cache that
still has its `node_modules/.bin/tavily-mcp` symlink while the packages it
points into have lost their `package.json`. The server then dies at startup
with `ERR_MODULE_NOT_FOUND`, surfacing in the agent as
`-32000: Connection closed`.

The wrapper now verifies that every cached package still has a readable
`package.json` and that the cached version matches the pinned one, reinstalling
automatically when either check fails. Point `TAVILY_NPM_CACHE` at `/tmp` again
only if you want that behaviour back.

## Security

- Keys stored in `~/.tavily-mcp-manager/keys.env`, never in repo
- Values are written single-quoted, so nothing in a key is ever expanded as
  shell syntax when the file is sourced. Files written by versions before 0.3.0
  used double quotes and are migrated automatically on first run, with the
  original kept as `keys.env.bak`
- Config writes take a lock and land via atomic rename, so several agents
  rotating at once cannot corrupt `config.json`
- CLI masks key values in output
- Recommended permissions:

```bash
chmod 700 ~/.tavily-mcp-manager
chmod 600 ~/.tavily-mcp-manager/keys.env ~/.tavily-mcp-manager/config.json
```

## Troubleshooting

```bash
tavily-manager doctor
```

Common fixes:

```bash
npm i -g tavily-mcp-manager
tavily-manager init
tavily-manager add tvly-...
chmod 700 ~/.tavily-mcp-manager
chmod 600 ~/.tavily-mcp-manager/keys.env ~/.tavily-mcp-manager/config.json
```

Disable noisy startup checks: `TAVILY_USAGE_STARTUP_CHECK=0 tavily-mcp-manager`

## Development

```
src/
  cli/tavily-manager        # command handling
  mcp/tavily-mcp-manager    # MCP wrapper around tavily-mcp@latest
dist/
  cli.js                    # bin wrapper for tavily-manager
  mcp-wrapper.js            # bin wrapper for tavily-mcp-manager
```

```bash
npm run check   # syntax only
npm test        # behavioural suite
```

The suite needs no network and spends no credits: it runs against a mock
`/usage` endpoint and a synthetic `node_modules` tree.

```
tests/
  run.sh          # entry point; pass suite names to run a subset
  helpers.sh      # assertions, sandboxes, mock curl
  test_store.sh   # quoting, migration, CRUD, concurrent writes
  test_cache.sh   # cache integrity and version pinning
  test_rotate.sh  # rotation, shared accounts, usage cache, breakdown
  test_install.sh # mcp install: config patching, dry run, idempotency
```
