# Tavily MCP Manager

Last updated: 2026-04-28

Tavily MCP Manager is a small global CLI for running `tavily-mcp` in Codex with switchable Tavily API keys. It gives you one command for key management and one command that Codex can use as the MCP server entrypoint.

## What It Solves

Codex needs a stable MCP command, but Tavily keys can run low, rotate between accounts, or need local isolation. This package keeps Tavily secrets outside your project, tracks the active key, checks usage, and starts `tavily-mcp@latest` with the selected key.

It ships two executables:

- `tavily-manager`: CLI for key setup, switching, usage checks, diagnostics, and rotation.
- `tavily-mcp-manager`: MCP startup wrapper for Codex.

The package metadata exposes both commands:

```json
{
  "bin": {
    "tavily-manager": "./dist/cli.js",
    "tavily-mcp-manager": "./dist/mcp-wrapper.js"
  }
}
```

## Quick Start

Install globally:

```bash
npm i -g tavily-mcp-manager
```

Initialize local storage and add your first key:

```bash
tavily-manager init
tavily-manager add tvly-... --alias personal
tavily-manager doctor
```

Print the Codex MCP config block:

```bash
tavily-manager mcp config codex
```

Add that block to your global Codex config:

```toml
[mcp_servers.tavily]
command = "tavily-mcp-manager"
args = []
```

For local development from this repo:

```bash
npm link
tavily-manager init
tavily-manager add tvly-...
tavily-manager doctor
```

If you do not want to link the package globally during local development, use
the absolute path to your own checkout's wrapper:

```toml
[mcp_servers.tavily]
command = "/absolute/path/to/tavily-mcp-manager/dist/mcp-wrapper.js"
args = []
```

## CLI Commands

Key setup and switching:

```bash
tavily-manager init
tavily-manager add tvly-...
tavily-manager add tvly-... --alias work
tavily-manager list
tavily-manager current
tavily-manager switch 2
tavily-manager switch work
```

Key maintenance:

```bash
tavily-manager key add tvly-... --alias backup
tavily-manager key rename 2 backup
tavily-manager key remove backup
```

Usage and rotation:

```bash
tavily-manager usage
tavily-manager usage all
tavily-manager rotate --dry-run
tavily-manager rotate
```

Diagnostics and MCP output:

```bash
tavily-manager doctor
tavily-manager mcp status
tavily-manager mcp config codex
```

## Codex MCP Setup

The recommended Codex config uses the global package command:

```toml
[mcp_servers.tavily]
command = "tavily-mcp-manager"
args = []
```

At startup, `tavily-mcp-manager` reads the active key from the manager config, exports it as `TAVILY_API_KEY`, optionally checks remaining usage, then runs:

```bash
npx -y tavily-mcp@latest
```

Enable automatic key rotation before MCP startup:

```bash
TAVILY_AUTO_ROTATE=1 tavily-mcp-manager
```

When auto-rotation is enabled, the wrapper switches away from the active key only if it is below the configured threshold and another usable key has more remaining credits.

## Config Paths

By default, state lives under `~/.codex/tavily`:

```text
~/.codex/tavily/keys.env      # Tavily API key values
~/.codex/tavily/config.json   # active key, aliases, and metadata
```

Secret file example:

```bash
TAVILY_API_KEY_1="tvly-..."
TAVILY_API_KEY_2="tvly-..."
```

Metadata example:

```json
{
  "version": 1,
  "activeKey": "2",
  "keys": {
    "1": {
      "label": null,
      "envVar": "TAVILY_API_KEY_1",
      "createdAt": "2026-04-28T00:00:00.000Z"
    },
    "2": {
      "label": "work",
      "envVar": "TAVILY_API_KEY_2",
      "createdAt": "2026-04-28T00:00:00.000Z"
    }
  }
}
```

Optional environment overrides:

- `TAVILY_HOME`: manager home path, default `~/.codex/tavily`.
- `TAVILY_CONFIG_FILE`: metadata config path.
- `TAVILY_KEYS_FILE`: secret key file path.
- `TAVILY_NPM_CACHE`: npm cache path for the MCP wrapper, default `/tmp/codex-npm-cache`.
- `TAVILY_USAGE_WARNING_PERCENT`: low-credit warning threshold, default `5`.
- `TAVILY_USAGE_STARTUP_CHECK`: set to `0` to skip startup usage checks.
- `TAVILY_AUTO_ROTATE`: set to `1` to rotate before MCP startup.
- `TAVILY_ROTATE_THRESHOLD_PERCENT`: minimum remaining percentage for auto-rotate.
- `TAVILY_PROJECT_ID`: optional Tavily project header for usage API calls.

## Security Model

API keys are not stored in this repository. The CLI writes secrets to `~/.codex/tavily/keys.env` and metadata to `~/.codex/tavily/config.json`.

Recommended permissions:

```bash
chmod 700 ~/.codex/tavily
chmod 600 ~/.codex/tavily/keys.env ~/.codex/tavily/config.json
```

The MCP wrapper exports only the selected key as `TAVILY_API_KEY` for the child `tavily-mcp@latest` process. It does not print full keys. CLI output masks key values when displaying active or listed keys.

Usage checks call Tavily directly:

```text
GET https://api.tavily.com/usage
Authorization: Bearer <active-key>
```

## Troubleshooting

Run the doctor first:

```bash
tavily-manager doctor
```

It checks:

- whether the manager home, secret file, and config file exist.
- whether key files have recommended permissions.
- whether `node`, `npm`, `npx`, and `curl` are available.
- whether `tavily-mcp-manager` is on `PATH`.
- whether the active key exists and is accepted by Tavily's `/usage` API.

Common fixes:

```bash
npm i -g tavily-mcp-manager
tavily-manager init
tavily-manager add tvly-...
tavily-manager switch <slot|alias>
chmod 700 ~/.codex/tavily
chmod 600 ~/.codex/tavily/keys.env ~/.codex/tavily/config.json
```

If Codex cannot find the MCP command, use the direct path shown by:

```bash
tavily-manager mcp config codex
```

If startup usage checks are noisy or blocked by network policy, disable only the startup check:

```bash
TAVILY_USAGE_STARTUP_CHECK=0 tavily-mcp-manager
```

## Examples

Add two keys and switch by alias:

```bash
tavily-manager add tvly-... --alias personal
tavily-manager add tvly-... --alias work
tavily-manager switch work
tavily-manager current
```

Review all key usage:

```bash
tavily-manager usage all
```

Dry-run rotation, then rotate:

```bash
tavily-manager rotate --dry-run
tavily-manager rotate
```

Use auto-rotation for Codex MCP startup:

```toml
[mcp_servers.tavily]
command = "tavily-mcp-manager"
args = []
env = { TAVILY_AUTO_ROTATE = "1" }
```

## Development

Implementation lives under `src/`; package entrypoints live under `dist/`:

```text
dist/
  cli.js             # package bin wrapper for tavily-manager
  mcp-wrapper.js     # package bin wrapper for tavily-mcp-manager
src/
  cli/tavily-manager        # command handling
  mcp/tavily-mcp-manager    # MCP startup wrapper around tavily-mcp@latest
```

Run checks:

```bash
npm run check
```
