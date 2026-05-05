#!/usr/bin/env bash

mcp_command_path() {
  if command -v tavily-mcp-manager >/dev/null 2>&1; then
    printf '%s' "tavily-mcp-manager"
  elif [[ -x "$repo_root/dist/mcp-wrapper.js" ]]; then
    printf '%s' "$repo_root/dist/mcp-wrapper.js"
  else
    printf '%s' "$repo_root/src/mcp/tavily-mcp-manager"
  fi
}

mcp_config_codex() {
  local command_path
  command_path="$(mcp_command_path)"
  cat <<EOF
[mcp_servers.tavily]
command = "$command_path"
args = []
EOF
}

mcp_config_claude() {
  local command_path
  command_path="$(mcp_command_path)"
  cat <<EOF
{
  "mcpServers": {
    "tavily": {
      "command": "$command_path",
      "args": []
    }
  }
}
EOF
}

mcp_config_gemini() {
  mcp_config_claude
}

mcp_config_opencode() {
  local command_path
  command_path="$(mcp_command_path)"
  cat <<EOF
{
  "mcp": {
    "tavily": {
      "type": "local",
      "command": ["$command_path"],
      "enabled": true,
      "environment": {}
    }
  }
}
EOF
}

mcp_config_list() {
  printf '%s\n' "Supported agents:"
  printf '  %-12s %s\n' "codex" "OpenAI Codex (TOML format)"
  printf '  %-12s %s\n' "claude" "Claude Code (JSON format)"
  printf '  %-12s %s\n' "gemini" "Gemini CLI (JSON format)"
  printf '  %-12s %s\n' "opencode" "OpenCode (JSON format)"
}
