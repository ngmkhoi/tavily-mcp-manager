#!/usr/bin/env bash

resolve_key_ref() {
  store resolve "$1"
}

current_id() {
  store active
}

key_meta() {
  store meta "$1"
}

key_env_for_id() {
  local meta slot label env_var
  meta="$(key_meta "$1")"
  IFS='|' read -r slot label env_var <<<"$meta"
  printf '%s' "$env_var"
}

key_label_for_id() {
  local meta slot label env_var
  meta="$(key_meta "$1")"
  IFS='|' read -r slot label env_var <<<"$meta"
  printf '%s' "$label"
}

key_title() {
  local id="$1"
  local label="$2"
  if [[ -n "$label" ]]; then
    printf '#%s %s' "$id" "$label"
  else
    printf '#%s' "$id"
  fi
}

print_store_paths() {
  printf '\n'
  section_title "Storage"
  ui_kv "secrets" "$keys_file"
  ui_kv "config" "$config_file"
}

key_for_id() {
  local id="$1"
  local env_var
  env_var="$(key_env_for_id "$id")"
  printf '%s' "${!env_var:-}"
}

add_key() {
  local raw
  raw="$(store add "$@")"
  load_store

  local id label env_var key
  IFS='|' read -r id label env_var <<<"$raw"
  key="${!env_var:-}"

  headline
  ui_status "saved" "$(key_title "$id" "$label")"
  ui_kv "api key" "$(mask_key "$key")"
  print_store_paths
}

rename_key() {
  local raw id label env_var
  raw="$(store rename "$@")"
  IFS='|' read -r id label env_var <<<"$raw"
  headline
  ui_status "renamed" "$(key_title "$id" "$label")"
}

remove_key() {
  local raw id label next
  raw="$(store remove "$@")"
  IFS='|' read -r id label next <<<"$raw"
  headline
  ui_status "removed" "#$id" "$yellow"
  if [[ -n "$next" ]]; then
    ui_kv "active" "#$next"
  fi
  print_store_paths
}

switch_key() {
  local raw id label env_var key
  raw="$(store switch "$1")"
  load_store
  IFS='|' read -r id label env_var <<<"$raw"
  key="${!env_var:-}"
  headline
  ui_status "active" "$(key_title "$id" "$label")"
  ui_kv "api key" "$(mask_key "$key")"
  print_store_paths
}

list_keys() {
  load_store
  local current id label env_var key marker alias
  current="$(current_id)"
  headline
  section_title "Keys"
  printf '%-5s %-8s %-18s %s\n' "Use" "Slot" "Alias" "API key"
  printf '%-5s %-8s %-18s %s\n' "-----" "--------" "------------------" "----------------------------"
  while IFS='|' read -r id label env_var; do
    key="${!env_var:-}"
    marker=""
    [[ "$id" == "$current" ]] && marker="${green}yes${reset}"
    alias="${label:--}"
    if [[ -z "$key" ]]; then
      printf '%-5b %-8s %-18s %b\n' "$marker" "#$id" "$alias" "${red}missing${reset}"
    else
      printf '%-5b %-8s %-18s %s\n' "$marker" "#$id" "$alias" "$(mask_key "$key")"
    fi
  done < <(store list)
  print_store_paths
}

show_current() {
  load_store
  local id label env_var key
  id="$(current_id)"
  if [[ -z "$id" ]]; then
    headline
    ui_empty "No active Tavily key."
    return
  fi
  IFS='|' read -r id label env_var <<<"$(key_meta "$id")"
  key="${!env_var:-}"
  headline
  if [[ -z "$key" ]]; then
    ui_status "active" "$(key_title "$id" "$label")"
    ui_kv "api key" "${red}missing${reset}"
  else
    ui_status "active" "$(key_title "$id" "$label")"
    ui_kv "api key" "$(mask_key "$key")"
  fi
  print_store_paths
}

init_store() {
  local old_path="$HOME/.codex/tavily"
  if [[ -d "$old_path" && ! -d "$tavily_home" ]]; then
    mkdir -p "$(dirname "$tavily_home")"
    mv "$old_path" "$tavily_home"
    ui_status "migrated" "Moved data from $old_path to $tavily_home"
  fi
  store active >/dev/null
  headline
  ui_status "ready" "Tavily manager storage initialized"
  print_store_paths
  printf '\n'
  ui_kv "next" "tavily-manager add tvly-..."
}

file_mode() {
  local file="$1"
  if stat -f '%Lp' "$file" >/dev/null 2>&1; then
    stat -f '%Lp' "$file"
  else
    stat -c '%a' "$file"
  fi
}

doctor_ok=0
doctor_warn=0
doctor_fail=0

doctor_pass() {
  doctor_ok=$((doctor_ok + 1))
  printf '  %s%-6s%s %s\n' "$green" "OK" "$reset" "$1"
}

doctor_note() {
  doctor_warn=$((doctor_warn + 1))
  printf '  %s%-6s%s %s\n' "$yellow" "WARN" "$reset" "$1"
}

doctor_error() {
  doctor_fail=$((doctor_fail + 1))
  printf '  %s%-6s%s %s\n' "$red" "FAIL" "$reset" "$1"
}

active_meta_from_config() {
  TAVILY_CONFIG_FILE_PATH="$config_file" node -e '
const fs = require("node:fs");
const config = JSON.parse(fs.readFileSync(process.env.TAVILY_CONFIG_FILE_PATH, "utf8"));
const activeKey = config.activeKey;
const record = activeKey && config.keys ? config.keys[activeKey] : null;
if (!record || !record.envVar) process.exit(1);
console.log(`${activeKey}|${record.label || ""}|${record.envVar}`);
'
}

doctor() {
  headline
  print_store_paths
  printf '\n'
  section_title "Checks"

  if [[ -d "$tavily_home" ]]; then
    doctor_pass "home directory exists: $tavily_home"
  else
    doctor_error "home directory is missing: $tavily_home"
  fi

  if [[ -f "$keys_file" ]]; then
    doctor_pass "secrets file exists"
    mode="$(file_mode "$keys_file")"
    if [[ "$mode" == "600" ]]; then
      doctor_pass "secrets file permission is 600"
    else
      doctor_note "secrets file permission is $mode, recommended 600"
    fi
  else
    doctor_error "secrets file is missing"
  fi

  if [[ -f "$config_file" ]]; then
    doctor_pass "config file exists"
    mode="$(file_mode "$config_file")"
    if [[ "$mode" == "600" ]]; then
      doctor_pass "config file permission is 600"
    else
      doctor_note "config file permission is $mode, recommended 600"
    fi
  else
    doctor_error "config file is missing"
  fi

  local tool
  for tool in node npm npx curl; do
    if command -v "$tool" >/dev/null 2>&1; then
      doctor_pass "$tool is available: $(command -v "$tool")"
    else
      doctor_error "$tool is not available"
    fi
  done

  if command -v tavily-mcp-manager >/dev/null 2>&1; then
    doctor_pass "tavily-mcp-manager is linked: $(command -v tavily-mcp-manager)"
  else
    doctor_note "tavily-mcp-manager is not on PATH; run npm link or use the direct dist/mcp-wrapper.js path in Codex config"
  fi

  local active_meta active_id active_label active_env_var active_key
  if [[ -f "$config_file" ]] && active_meta="$(active_meta_from_config 2>/dev/null)"; then
    IFS='|' read -r active_id active_label active_env_var <<<"$active_meta"
    doctor_pass "active key is configured: $(key_title "$active_id" "$active_label")"
    if [[ -f "$keys_file" ]]; then
      # shellcheck disable=SC1090
      source "$keys_file"
      active_key="${!active_env_var:-}"
      if [[ -n "$active_key" ]]; then
        doctor_pass "active secret exists in keys.env as $active_env_var"
        if curl --fail --silent --show-error \
          --request GET \
          --url "https://api.tavily.com/usage" \
          --header "Authorization: Bearer ${active_key}" >/dev/null 2>&1; then
          doctor_pass "Tavily usage API accepts the active key"
        else
          doctor_error "Tavily usage API rejected or could not verify the active key"
        fi
      else
        doctor_error "active secret is missing in keys.env: $active_env_var"
      fi
    fi
  else
    doctor_error "active key is not configured"
  fi

  printf '\n'
  section_title "Summary"
  ui_kv "ok" "$doctor_ok"
  ui_kv "warnings" "$doctor_warn"
  ui_kv "failures" "$doctor_fail"
  if (( doctor_fail > 0 )); then
    exit 1
  fi
}

mcp_status() {
  load_store
  local id label env_var key
  id="$(current_id)"
  IFS='|' read -r id label env_var <<<"$(key_meta "$id")"
  key="${!env_var:-}"

  headline
  section_title "MCP Runtime"
  ui_kv "command" "$(mcp_command_path)"
  ui_kv "package" "tavily-mcp@${TAVILY_MCP_VERSION:-0.2.19}"
  if [[ -n "$key" ]]; then
    ui_kv "active" "$(key_title "$id" "$label")  $(mask_key "$key")"
  else
    ui_kv "active" "$(key_title "$id" "$label")  ${red}missing${reset}"
  fi
  ui_kv "auto rotate" "${TAVILY_AUTO_ROTATE:-0}"
  ui_kv "threshold" "${TAVILY_ROTATE_THRESHOLD_PERCENT:-${TAVILY_USAGE_WARNING_PERCENT:-5}}%"
  ui_kv "usage check" "${TAVILY_USAGE_STARTUP_CHECK:-0}"
  ui_kv "usage cache" "${TAVILY_USAGE_CACHE_TTL_SECONDS:-300}s at $(usage_cache_dir)"

  local cache_dir cache_stamp
  cache_dir="${TAVILY_NPM_CACHE:-$tavily_home/npm-cache}"
  cache_stamp="$cache_dir/.tavily-mcp-installed"
  ui_kv "npm cache" "$cache_dir"
  if [[ -f "$cache_stamp" ]]; then
    ui_kv "cached" "$(cat "$cache_stamp" 2>/dev/null)"
  else
    ui_kv "cached" "${yellow}not installed yet${reset}"
  fi
  if [[ "$cache_dir" == /tmp/* || "$cache_dir" == /private/tmp/* ]]; then
    ui_status "warning" "npm cache lives under /tmp, which the OS prunes; the install will eventually break" "$yellow"
  fi
  print_store_paths
}
