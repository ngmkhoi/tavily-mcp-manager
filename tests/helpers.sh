#!/usr/bin/env bash
# Shared assertions and sandbox setup. Kept bash 3.2 compatible because that is
# what ships with macOS, which is the primary platform for this tool.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGER="$REPO_ROOT/src/cli/tavily-manager"
WRAPPER="$REPO_ROOT/src/mcp/tavily-mcp-manager"

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

_red=""; _green=""; _yellow=""; _reset=""
if [[ -t 1 ]]; then
  _red=$'\033[31m'; _green=$'\033[32m'; _yellow=$'\033[33m'; _reset=$'\033[0m'
fi

it() {
  CURRENT_TEST="$1"
  TESTS_RUN=$((TESTS_RUN + 1))
}

pass() {
  printf '  %sok%s   %s\n' "$_green" "$_reset" "$CURRENT_TEST"
}

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  %sFAIL%s %s\n' "$_red" "$_reset" "$CURRENT_TEST"
  printf '       %s\n' "$1"
}

assert_eq() {
  if [[ "$1" == "$2" ]]; then
    pass
  else
    fail "expected: [$2]
       actual:   [$1]"
  fi
}

assert_contains() {
  if [[ "$1" == *"$2"* ]]; then
    pass
  else
    fail "expected output to contain: [$2]
       actual: [$1]"
  fi
}

assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then
    pass
  else
    fail "expected output NOT to contain: [$2]
       actual: [$1]"
  fi
}

assert_success() {
  if [[ "$1" == "0" ]]; then
    pass
  else
    fail "expected exit code 0, got $1"
  fi
}

assert_failure() {
  if [[ "$1" != "0" ]]; then
    pass
  else
    fail "expected a non-zero exit code, got 0"
  fi
}

# Each test file gets an isolated TAVILY_HOME so nothing touches the real one.
new_sandbox() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/tavily-test.XXXXXX")"
  SANDBOXES="$SANDBOXES $dir"
  printf '%s' "$dir"
}

cleanup_sandboxes() {
  local dir
  for dir in $SANDBOXES; do
    [[ -n "$dir" && -d "$dir" ]] && rm -rf "$dir"
  done
  SANDBOXES=""
}
SANDBOXES=""

# Stands in for the Tavily usage API. Reads the bearer token out of the curl
# arguments and replies with whatever JSON the test registered for that key,
# so rotation logic can be exercised without network access or real credits.
install_mock_curl() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/curl" <<'MOCK'
#!/usr/bin/env bash
token=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--header" && "$arg" == "Authorization: Bearer "* ]]; then
    token="${arg#Authorization: Bearer }"
  fi
  prev="$arg"
done

fixture="$MOCK_USAGE_DIR/$token.json"
if [[ -f "$fixture" ]]; then
  cat "$fixture"
  exit 0
fi
exit 22
MOCK
  chmod +x "$bin_dir/curl"
}

# Builds a /usage response. Keys on the same Tavily account must report the
# same account block, which is what the shared-account check keys off.
usage_fixture() {
  local plan_usage="$1"
  local plan_limit="${2:-1000}"
  local search="${3:-0}"
  local research="${4:-0}"
  cat <<EOF
{
  "key": { "usage": $plan_usage, "search_usage": $search, "research_usage": $research },
  "account": {
    "current_plan": "Researcher",
    "plan_usage": $plan_usage,
    "plan_limit": $plan_limit,
    "paygo_usage": 0,
    "paygo_limit": 0,
    "search_usage": $search,
    "research_usage": $research
  }
}
EOF
}

summary() {
  printf '\n'
  if [[ "$TESTS_FAILED" == "0" ]]; then
    printf '%s%d passed%s\n' "$_green" "$TESTS_RUN" "$_reset"
  else
    printf '%s%d of %d failed%s\n' "$_red" "$TESTS_FAILED" "$TESTS_RUN" "$_reset"
  fi
  return "$TESTS_FAILED"
}
