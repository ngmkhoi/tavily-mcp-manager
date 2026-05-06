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

Print MCP config for your agent:

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
| **Diagnostics** | `doctor`, `mcp status`, `mcp config <agent>` |

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
| `TAVILY_NPM_CACHE` | `/tmp/tavily-mcp-npm-cache` | npm cache for MCP wrapper |
| `TAVILY_USAGE_WARNING_PERCENT` | `5` | Low-credit warning threshold |
| `TAVILY_USAGE_STARTUP_CHECK` | `1` | Set `0` to skip startup checks |
| `TAVILY_AUTO_ROTATE` | `0` | Set `1` to rotate before startup |
| `TAVILY_ROTATE_THRESHOLD_PERCENT` | — | Min remaining % for auto-rotate |
| `TAVILY_PROJECT_ID` | — | Tavily project header for usage API |

## Security

- Keys stored in `~/.tavily-mcp-manager/keys.env`, never in repo
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
npm run check
```
