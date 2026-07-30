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

# Environment the generated config carries. Auto-rotate is the whole point of
# this tool, so it is on by default. The npm cache no longer needs pinning here
# because its default already lives outside /tmp.
mcp_install_env_keys() {
  printf '%s\n' "TAVILY_AUTO_ROTATE"
}

mcp_install_env_value() {
  case "$1" in
    TAVILY_AUTO_ROTATE) printf '%s' "${TAVILY_INSTALL_AUTO_ROTATE:-1}" ;;
    *) printf '' ;;
  esac
}

mcp_env_json() {
  local key first=1
  printf '{'
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    [[ "$first" == "1" ]] || printf ', '
    printf '"%s": "%s"' "$key" "$(mcp_install_env_value "$key")"
    first=0
  done < <(mcp_install_env_keys)
  printf '}'
}

# --- printable config --------------------------------------------------------

mcp_config_codex() {
  local command_path
  command_path="$(mcp_command_path)"
  cat <<EOF
[mcp_servers.tavily]
command = "$command_path"
args = []

[mcp_servers.tavily.env]
TAVILY_AUTO_ROTATE = "$(mcp_install_env_value TAVILY_AUTO_ROTATE)"
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
      "args": [],
      "env": $(mcp_env_json)
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
      "environment": $(mcp_env_json)
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

# --- install -----------------------------------------------------------------

mcp_install_dry_run=0
mcp_install_force=0

mcp_install_would() {
  ui_status "dry run" "$1" "$yellow"
}

# A dry run must never claim it installed anything.
mcp_install_done() {
  if [[ "$mcp_install_dry_run" == "1" ]]; then
    ui_status "would install" "$1" "$yellow"
  else
    ui_status "installed" "$1"
  fi
}

# Runs an agent's own CLI so that agent stays the authority on its config
# format. Honours --dry-run by printing the command instead of running it.
mcp_run() {
  if [[ "$mcp_install_dry_run" == "1" ]]; then
    mcp_install_would "$*"
    return 0
  fi
  "$@"
}

mcp_env_args() {
  local flag="$1" key
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    printf '%s\n%s=%s\n' "$flag" "$key" "$(mcp_install_env_value "$key")"
  done < <(mcp_install_env_keys)
}

# Merges a value into a JSON file at a dotted path, creating the file when
# missing and leaving every other key untouched. A backup is written first
# because these files hold far more than our entry.
json_patch_file() {
  local file="$1" dotted="$2" value="$3"

  if [[ "$mcp_install_dry_run" == "1" ]]; then
    mcp_install_would "set $dotted in $file"
    return 0
  fi

  TAVILY_PATCH_FILE="$file" \
  TAVILY_PATCH_PATH="$dotted" \
  TAVILY_PATCH_VALUE="$value" \
  node -e '
const fs = require("node:fs");
const path = require("node:path");

const file = process.env.TAVILY_PATCH_FILE;
const dotted = process.env.TAVILY_PATCH_PATH.split(".");
const value = JSON.parse(process.env.TAVILY_PATCH_VALUE);

let doc = {};
if (fs.existsSync(file)) {
  const original = fs.readFileSync(file, "utf8");
  if (original.trim()) {
    try {
      doc = JSON.parse(original);
    } catch (error) {
      console.error(`${file} is not valid JSON, refusing to touch it: ${error.message}`);
      process.exit(1);
    }
  }
  fs.writeFileSync(`${file}.bak`, original);
}

let node = doc;
for (const segment of dotted.slice(0, -1)) {
  if (typeof node[segment] !== "object" || node[segment] === null) node[segment] = {};
  node = node[segment];
}
node[dotted[dotted.length - 1]] = value;

fs.mkdirSync(path.dirname(file), { recursive: true });
const tmp = `${file}.tmp.${process.pid}`;
fs.writeFileSync(tmp, JSON.stringify(doc, null, 2) + "\n");
fs.renameSync(tmp, file);
'
}

mcp_install_claude() {
  local command_path
  command_path="$(mcp_command_path)"

  if command -v claude >/dev/null 2>&1; then
    if claude mcp get tavily >/dev/null 2>&1; then
      if [[ "$mcp_install_force" != "1" ]]; then
        ui_status "skipped" "tavily is already registered with Claude Code" "$yellow"
        ui_kv "hint" "re-run with --force to replace it"
        return 0
      fi
      mcp_run claude mcp remove tavily -s user >/dev/null 2>&1 || true
    fi

    local env_args=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && env_args+=("$line")
    done < <(mcp_env_args -e)

    if mcp_run claude mcp add tavily -s user "${env_args[@]}" -- "$command_path" >/dev/null 2>&1; then
      mcp_install_done "Claude Code (user scope)"
      ui_kv "command" "$command_path"
      return 0
    fi
    ui_status "failed" "claude mcp add did not succeed" "$red"
    return 1
  fi

  ui_status "fallback" "claude CLI not found, patching ~/.claude.json" "$yellow"
  json_patch_file "$HOME/.claude.json" "mcpServers.tavily" \
    "{\"command\": \"$command_path\", \"args\": [], \"env\": $(mcp_env_json)}" || return 1
  mcp_install_done "Claude Code"
  ui_kv "file" "$HOME/.claude.json"
}

mcp_install_codex() {
  local command_path
  command_path="$(mcp_command_path)"

  if ! command -v codex >/dev/null 2>&1; then
    # config.toml is TOML, and appending blindly would duplicate an existing
    # [mcp_servers.tavily] block. Rather than half-parse TOML in bash, tell the
    # user exactly what to paste.
    ui_status "manual" "codex CLI not found; add this to ~/.codex/config.toml" "$yellow"
    printf '\n'
    mcp_config_codex
    return 1
  fi

  if codex mcp get tavily >/dev/null 2>&1; then
    if [[ "$mcp_install_force" != "1" ]]; then
      ui_status "skipped" "tavily is already registered with Codex" "$yellow"
      ui_kv "hint" "re-run with --force to replace it"
      return 0
    fi
    mcp_run codex mcp remove tavily >/dev/null 2>&1 || true
  fi

  local env_args=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && env_args+=("$line")
  done < <(mcp_env_args --env)

  if mcp_run codex mcp add tavily "${env_args[@]}" -- "$command_path" >/dev/null 2>&1; then
    mcp_install_done "Codex"
    ui_kv "command" "$command_path"
    return 0
  fi
  ui_status "failed" "codex mcp add did not succeed" "$red"
  return 1
}

mcp_install_gemini() {
  local command_path
  command_path="$(mcp_command_path)"

  if command -v gemini >/dev/null 2>&1; then
    if [[ "$mcp_install_force" == "1" ]]; then
      mcp_run gemini mcp remove tavily >/dev/null 2>&1 || true
    fi

    local env_args=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && env_args+=("$line")
    done < <(mcp_env_args -e)

    if mcp_run gemini mcp add tavily "${env_args[@]}" -- "$command_path" >/dev/null 2>&1; then
      mcp_install_done "Gemini CLI"
      ui_kv "command" "$command_path"
      return 0
    fi
    ui_status "fallback" "gemini mcp add failed, patching settings.json" "$yellow"
  fi

  json_patch_file "$HOME/.gemini/settings.json" "mcpServers.tavily" \
    "{\"command\": \"$command_path\", \"args\": [], \"env\": $(mcp_env_json)}" || return 1
  mcp_install_done "Gemini CLI"
  ui_kv "file" "$HOME/.gemini/settings.json"
}

mcp_install_opencode() {
  local command_path config_path
  command_path="$(mcp_command_path)"
  config_path="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"

  # `opencode mcp add` prompts interactively, so the file is the reliable path.
  json_patch_file "$config_path" "mcp.tavily" \
    "{\"type\": \"local\", \"command\": [\"$command_path\"], \"enabled\": true, \"environment\": $(mcp_env_json)}" || return 1
  mcp_install_done "OpenCode"
  ui_kv "file" "$config_path"
}

mcp_install() {
  local agent=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) mcp_install_dry_run=1; shift ;;
      --force)   mcp_install_force=1; shift ;;
      --*)       usage; exit 2 ;;
      *)         agent="$1"; shift ;;
    esac
  done

  headline

  if [[ -z "$agent" || "$agent" == "list" ]]; then
    mcp_config_list
    printf '\n'
    ui_kv "usage" "tavily-manager mcp install <agent> [--dry-run] [--force]"
    ui_kv "all" "tavily-manager mcp install all"
    return 0
  fi

  if [[ "$agent" == "all" ]]; then
    local installed=0 needs=0 target
    for target in codex claude gemini opencode; do
      section_title "$target"
      if "mcp_install_$target"; then
        installed=$((installed + 1))
      else
        needs=$((needs + 1))
      fi
      printf '\n'
    done
    section_title "Summary"
    ui_kv "ok" "$installed"
    ui_kv "attention" "$needs"
    return 0
  fi

  case "$agent" in
    codex|claude|gemini|opencode)
      section_title "$agent"
      "mcp_install_$agent"
      ;;
    *)
      ui_status "unknown" "no such agent: $agent" "$red"
      printf '\n'
      mcp_config_list
      exit 2
      ;;
  esac
}
