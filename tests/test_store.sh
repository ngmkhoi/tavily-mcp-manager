#!/usr/bin/env bash
# Key storage: quoting, migration, CRUD, and concurrent-write safety.

printf '\nstore\n'

HOME_DIR="$(new_sandbox)"
export TAVILY_HOME="$HOME_DIR"

"$MANAGER" init >/dev/null 2>&1

# --- quoting -----------------------------------------------------------------
# The value below contains the two characters that broke the old double-quoted
# writer: $ (command substitution when sourced) and ' (breaks naive quoting).
TRICKY="tvly-dev-\$(id -un)-quote'x-back\\slash"

"$MANAGER" add "$TRICKY" --alias tricky >/dev/null 2>&1

it "stores a key containing \$, ' and \\ without altering it"
config_file="$TAVILY_HOME/config.json"
keys_file="$TAVILY_HOME/keys.env"
legacy_active_file="$TAVILY_HOME/active-key"
# shellcheck disable=SC1090
source "$REPO_ROOT/src/cli/store.sh"
assert_eq "$(store get 1)" "$TRICKY"

it "does not execute command substitution when keys.env is sourced"
sourced="$(bash -c 'source "$1"; printf "%s" "$TAVILY_API_KEY_1"' _ "$keys_file")"
assert_eq "$sourced" "$TRICKY"

it "writes keys.env in single-quoted form"
assert_contains "$(cat "$keys_file")" "TAVILY_API_KEY_1='tvly-dev-\$(id -un)"

it "rejects a duplicate API key"
"$MANAGER" add "$TRICKY" >/dev/null 2>&1
assert_failure "$?"

# --- migration ---------------------------------------------------------------
MIG_DIR="$(new_sandbox)"
printf 'TAVILY_API_KEY_1="tvly-dev-$(id -un)-OLD"\n# a comment\nTAVILY_API_KEY_2="plain-value"\n' > "$MIG_DIR/keys.env"
printf '{"version":1,"activeKey":"1","keys":{"1":{"label":"old","envVar":"TAVILY_API_KEY_1"},"2":{"label":"two","envVar":"TAVILY_API_KEY_2"}}}\n' > "$MIG_DIR/config.json"

TAVILY_HOME="$MIG_DIR" "$MANAGER" current >/dev/null 2>&1
migrated="$(cat "$MIG_DIR/keys.env")"

it "migrates legacy double-quoted values to the safe form"
assert_contains "$migrated" "TAVILY_API_KEY_1='tvly-dev-\$(id -un)-OLD'"

it "preserves the literal value across migration"
sourced="$(bash -c 'source "$1"; printf "%s" "$TAVILY_API_KEY_1"' _ "$MIG_DIR/keys.env")"
assert_eq "$sourced" 'tvly-dev-$(id -un)-OLD'

it "keeps comments during migration"
assert_contains "$migrated" "# a comment"

it "backs up keys.env before rewriting it"
assert_contains "$(cat "$MIG_DIR/keys.env.bak" 2>/dev/null)" 'TAVILY_API_KEY_1="tvly-dev-$(id -un)-OLD"'

it "does not rewrite an already-migrated file"
before="$(cat "$MIG_DIR/keys.env")"
rm -f "$MIG_DIR/keys.env.bak"
TAVILY_HOME="$MIG_DIR" "$MANAGER" current >/dev/null 2>&1
after="$(cat "$MIG_DIR/keys.env")"
if [[ "$before" == "$after" && ! -f "$MIG_DIR/keys.env.bak" ]]; then pass; else fail "file was rewritten unnecessarily"; fi

# --- CRUD --------------------------------------------------------------------
CRUD_DIR="$(new_sandbox)"
export TAVILY_HOME="$CRUD_DIR"
"$MANAGER" init >/dev/null 2>&1
"$MANAGER" add tvly-dev-aaa --alias alpha >/dev/null 2>&1
"$MANAGER" add tvly-dev-bbb --alias beta >/dev/null 2>&1

it "makes the first added key active"
assert_contains "$("$MANAGER" current 2>&1)" "#1 alpha"

it "switches by alias"
"$MANAGER" switch beta >/dev/null 2>&1
assert_contains "$("$MANAGER" current 2>&1)" "#2 beta"

it "rejects a duplicate alias"
"$MANAGER" add tvly-dev-ccc --alias beta >/dev/null 2>&1
assert_failure "$?"

it "renames an alias"
"$MANAGER" key rename 1 renamed >/dev/null 2>&1
assert_contains "$("$MANAGER" list 2>&1)" "renamed"

it "reassigns the active key when the active one is removed"
"$MANAGER" switch 1 >/dev/null 2>&1
"$MANAGER" key remove 1 >/dev/null 2>&1
assert_contains "$("$MANAGER" current 2>&1)" "#2 beta"

it "drops the secret from keys.env when a key is removed"
assert_not_contains "$(cat "$CRUD_DIR/keys.env")" "tvly-dev-aaa"

# --- concurrency -------------------------------------------------------------
# Several agents may auto-rotate at the same moment. Without the lock this is a
# read-modify-write race that can truncate config.json.
LOCK_DIR="$(new_sandbox)"
export TAVILY_HOME="$LOCK_DIR"
"$MANAGER" init >/dev/null 2>&1
for i in 1 2 3 4 5; do
  "$MANAGER" add "tvly-dev-key$i" --alias "k$i" >/dev/null 2>&1
done

it "keeps config.json valid under concurrent switches"
for i in 1 2 3 4 5; do
  "$MANAGER" switch "$i" >/dev/null 2>&1 &
done
wait
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$LOCK_DIR/config.json" 2>/dev/null
assert_success "$?"

it "keeps all five secrets intact under concurrent writes"
count="$(grep -c '^TAVILY_API_KEY_' "$LOCK_DIR/keys.env")"
assert_eq "$count" "5"

it "leaves no lock directory behind"
if [[ -d "$LOCK_DIR/config.json.lock" ]]; then fail "lock directory was not released"; else pass; fi
