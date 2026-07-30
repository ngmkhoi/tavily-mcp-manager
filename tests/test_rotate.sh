#!/usr/bin/env bash
# Rotation and usage reporting, driven against a mock /usage endpoint so no
# real credits are spent and results are deterministic.

printf '\nrotate\n'

ROT_DIR="$(new_sandbox)"
export TAVILY_HOME="$ROT_DIR"
export MOCK_USAGE_DIR="$ROT_DIR/fixtures"
mkdir -p "$MOCK_USAGE_DIR"

MOCK_BIN="$ROT_DIR/bin"
install_mock_curl "$MOCK_BIN"
export PATH="$MOCK_BIN:$PATH"

"$MANAGER" init >/dev/null 2>&1
for i in 1 2 3; do
  "$MANAGER" add "tvly-dev-k$i" --alias "k$i" >/dev/null 2>&1
done

# Three separate accounts: #2 has the most credits left.
usage_fixture 500 1000 500 0 > "$MOCK_USAGE_DIR/tvly-dev-k1.json"
usage_fixture 100 1000 100 0 > "$MOCK_USAGE_DIR/tvly-dev-k2.json"
usage_fixture 900 1000 900 0 > "$MOCK_USAGE_DIR/tvly-dev-k3.json"

it "reports usage for a single key"
out="$("$MANAGER" usage k1 2>&1)"
assert_contains "$out" "500"

it "picks the key with the most remaining credits"
out="$("$MANAGER" rotate 2>&1)"
assert_contains "$out" "#2 k2"

it "actually switches the active key"
assert_contains "$("$MANAGER" current 2>&1)" "#2 k2"

it "does not switch during a dry run"
"$MANAGER" switch 1 >/dev/null 2>&1
"$MANAGER" rotate --dry-run >/dev/null 2>&1
assert_contains "$("$MANAGER" current 2>&1)" "#1 k1"

it "skips rotation when the active key is above the threshold"
"$MANAGER" switch 2 >/dev/null 2>&1
out="$("$MANAGER" rotate --only-if-current-below 50 2>&1)"
assert_contains "$out" "skipped"

it "rotates when the active key is below the threshold"
"$MANAGER" switch 3 >/dev/null 2>&1
"$MANAGER" rotate --only-if-current-below 50 >/dev/null 2>&1
assert_contains "$("$MANAGER" current 2>&1)" "#2 k2"

it "fails when no key clears the minimum"
usage_fixture 999 1000 999 0 > "$MOCK_USAGE_DIR/tvly-dev-k1.json"
usage_fixture 999 1000 999 0 > "$MOCK_USAGE_DIR/tvly-dev-k2.json"
usage_fixture 999 1000 999 0 > "$MOCK_USAGE_DIR/tvly-dev-k3.json"
"$MANAGER" rotate --min-remaining 5 >/dev/null 2>&1
assert_failure "$?"

# --- shared accounts ---------------------------------------------------------
printf '\nshared-account detection\n'

SHARE_DIR="$(new_sandbox)"
export TAVILY_HOME="$SHARE_DIR"
export MOCK_USAGE_DIR="$SHARE_DIR/fixtures"
mkdir -p "$MOCK_USAGE_DIR"
"$MANAGER" init >/dev/null 2>&1
for i in 1 2 3; do
  "$MANAGER" add "tvly-dev-s$i" --alias "s$i" >/dev/null 2>&1
done

# #1 and #2 are issued under one account, so they report identical account
# figures; rotating between them frees nothing.
usage_fixture 300 1000 300 0 > "$MOCK_USAGE_DIR/tvly-dev-s1.json"
usage_fixture 300 1000 300 0 > "$MOCK_USAGE_DIR/tvly-dev-s2.json"
usage_fixture 150 1000 150 0 > "$MOCK_USAGE_DIR/tvly-dev-s3.json"

it "warns when two keys report identical account credits"
out="$("$MANAGER" rotate 2>&1)"
assert_contains "$out" "likely share one Tavily account"

it "names both keys in the shared-account warning"
assert_contains "$out" "#1 #2"

it "stays silent when every key has its own account"
usage_fixture 300 1000 300 0 > "$MOCK_USAGE_DIR/tvly-dev-s1.json"
usage_fixture 400 1000 400 0 > "$MOCK_USAGE_DIR/tvly-dev-s2.json"
usage_fixture 150 1000 150 0 > "$MOCK_USAGE_DIR/tvly-dev-s3.json"
out="$("$MANAGER" rotate 2>&1)"
assert_not_contains "$out" "likely share one Tavily account"

# --- usage cache -------------------------------------------------------------
printf '\nusage cache\n'

CACHE_HOME="$(new_sandbox)"
export TAVILY_HOME="$CACHE_HOME"
export MOCK_USAGE_DIR="$CACHE_HOME/fixtures"
mkdir -p "$MOCK_USAGE_DIR"
"$MANAGER" init >/dev/null 2>&1
"$MANAGER" add tvly-dev-c1 --alias c1 >/dev/null 2>&1
usage_fixture 200 1000 200 0 > "$MOCK_USAGE_DIR/tvly-dev-c1.json"

it "populates the usage cache on a live fetch"
"$MANAGER" usage c1 >/dev/null 2>&1
if [[ -f "$CACHE_HOME/usage-cache/1.json" ]]; then pass; else fail "no cache file was written"; fi

it "serves from cache when caching is enabled"
# The fixture now says 900 used; a cached read must still report 200.
usage_fixture 900 1000 900 0 > "$MOCK_USAGE_DIR/tvly-dev-c1.json"
out="$(TAVILY_USAGE_USE_CACHE=1 "$MANAGER" usage c1 2>&1)"
assert_contains "$out" "200"

it "bypasses the cache by default so explicit checks are live"
out="$("$MANAGER" usage c1 2>&1)"
assert_contains "$out" "900"

it "ignores the cache once the TTL has elapsed"
usage_fixture 111 1000 111 0 > "$MOCK_USAGE_DIR/tvly-dev-c1.json"
out="$(TAVILY_USAGE_USE_CACHE=1 TAVILY_USAGE_CACHE_TTL_SECONDS=0 "$MANAGER" usage c1 2>&1)"
assert_contains "$out" "111"

# --- credit breakdown --------------------------------------------------------
printf '\ncredit breakdown\n'

it "shows the per-endpoint share of spend"
usage_fixture 100 1000 40 60 > "$MOCK_USAGE_DIR/tvly-dev-c1.json"
out="$("$MANAGER" usage c1 2>&1)"
assert_contains "$out" "share"

it "flags research-heavy spend"
# 60 of 100 credits went to research, which is the expensive endpoint.
assert_contains "$out" "research is 60.0% of spend"

it "does not flag search-heavy spend"
usage_fixture 100 1000 95 5 > "$MOCK_USAGE_DIR/tvly-dev-c1.json"
out="$("$MANAGER" usage c1 2>&1)"
assert_not_contains "$out" "of spend"
