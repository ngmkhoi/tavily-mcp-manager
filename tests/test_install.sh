#!/usr/bin/env bash
# `mcp install` writes into config files that hold far more than our entry, so
# these cover the destructive edges: never clobber unrelated keys, never write
# during a dry run, never touch a file we cannot parse.
#
# OpenCode is the agent driven by direct file patching, which makes it the one
# that exercises json_patch_file end to end without needing another CLI present.

printf '\nmcp install\n'

INS_DIR="$(new_sandbox)"
CONFIG="$INS_DIR/opencode.json"

write_existing_config() {
  cat > "$CONFIG" <<'JSON'
{
  "theme": "dark",
  "model": "gpt-5",
  "mcp": {
    "existing-server": { "type": "local", "command": ["foo"] }
  }
}
JSON
}

install_opencode() {
  OPENCODE_CONFIG="$CONFIG" "$MANAGER" mcp install opencode "$@" 2>&1
}

read_json() {
  node -e '
const fs = require("node:fs");
const doc = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const value = process.argv[2].split(".").reduce((acc, k) => (acc == null ? acc : acc[k]), doc);
process.stdout.write(value === undefined ? "" : String(value));
' "$CONFIG" "$1"
}

it "lists the supported agents when no agent is given"
assert_contains "$("$MANAGER" mcp install 2>&1)" "opencode"

it "rejects an unknown agent"
"$MANAGER" mcp install nosuchagent >/dev/null 2>&1
assert_failure "$?"

# --- dry run -----------------------------------------------------------------
write_existing_config
before="$(cat "$CONFIG")"

it "reports what a dry run would do"
assert_contains "$(install_opencode --dry-run)" "dry run"

it "does not claim to have installed during a dry run"
assert_not_contains "$(install_opencode --dry-run)" "  installed"

it "leaves the file untouched during a dry run"
assert_eq "$(cat "$CONFIG")" "$before"

# --- real write --------------------------------------------------------------
it "registers tavily"
install_opencode >/dev/null 2>&1
assert_eq "$(read_json 'mcp.tavily.type')" "local"

it "sets auto-rotate in the installed config"
# Omitting env is what let the /tmp cache problem reach every agent unnoticed.
assert_eq "$(read_json 'mcp.tavily.environment.TAVILY_AUTO_ROTATE')" "1"

it "marks the server enabled"
assert_eq "$(read_json 'mcp.tavily.enabled')" "true"

it "preserves unrelated top-level keys"
assert_eq "$(read_json 'theme')" "dark"

it "preserves other MCP servers"
assert_eq "$(read_json 'mcp.existing-server.type')" "local"

it "backs the file up before rewriting it"
assert_contains "$(cat "$CONFIG.bak")" "existing-server"

it "is idempotent"
snapshot="$(cat "$CONFIG")"
install_opencode >/dev/null 2>&1
assert_eq "$(cat "$CONFIG")" "$snapshot"

# --- creation ----------------------------------------------------------------
it "creates the config file and its parent directories"
CONFIG="$INS_DIR/nested/deep/opencode.json"
install_opencode >/dev/null 2>&1
assert_eq "$(read_json 'mcp.tavily.type')" "local"

# --- refuses to damage -------------------------------------------------------
it "refuses to write to a file that is not valid JSON"
CONFIG="$INS_DIR/broken.json"
printf '{ this is not json' > "$CONFIG"
install_opencode >/dev/null 2>&1
assert_failure "$?"

it "leaves an unparseable file exactly as it found it"
assert_eq "$(cat "$CONFIG")" '{ this is not json'

# --- generated config --------------------------------------------------------
printf '\nmcp config\n'

it "includes env in the printed Codex config"
assert_contains "$("$MANAGER" mcp config codex 2>&1)" "TAVILY_AUTO_ROTATE"

it "includes env in the printed Claude config"
assert_contains "$("$MANAGER" mcp config claude 2>&1)" "TAVILY_AUTO_ROTATE"

it "prints valid JSON for Claude"
"$MANAGER" mcp config claude 2>/dev/null | node -e '
let s = ""; process.stdin.on("data", d => s += d).on("end", () => JSON.parse(s));
'
assert_success "$?"

it "prints valid JSON for OpenCode"
"$MANAGER" mcp config opencode 2>/dev/null | node -e '
let s = ""; process.stdin.on("data", d => s += d).on("end", () => JSON.parse(s));
'
assert_success "$?"
