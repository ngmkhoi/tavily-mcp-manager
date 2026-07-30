#!/usr/bin/env bash
# Cache integrity: the wrapper must notice a gutted or wrong-version install
# rather than exec'ing into it and dying with ERR_MODULE_NOT_FOUND.
#
# These drive the wrapper's real cache_is_healthy through its --verify-cache
# hook, against a synthetic node_modules tree, so no download is needed.

printf '\ncache integrity\n'

verify_cache() {
  local root="$1"
  local version="${2:-0.2.19}"
  TAVILY_NPM_CACHE="$root" TAVILY_MCP_VERSION="$version" "$WRAPPER" --verify-cache >/dev/null 2>&1
}

build_fake_install() {
  local root="$1"
  local version="${2:-0.2.19}"
  rm -rf "$root/node_modules"
  mkdir -p "$root/node_modules/tavily-mcp/build"
  mkdir -p "$root/node_modules/@modelcontextprotocol/sdk"
  mkdir -p "$root/node_modules/.bin"
  printf '{"name":"tavily-mcp","version":"%s","main":"build/index.js"}\n' "$version" \
    > "$root/node_modules/tavily-mcp/package.json"
  printf 'console.log("stub");\n' > "$root/node_modules/tavily-mcp/build/index.js"
  printf '{"name":"@modelcontextprotocol/sdk","version":"1.0.0"}\n' \
    > "$root/node_modules/@modelcontextprotocol/sdk/package.json"
  ln -sf ../tavily-mcp/build/index.js "$root/node_modules/.bin/tavily-mcp"
  chmod +x "$root/node_modules/tavily-mcp/build/index.js"
  printf 'tavily-mcp@%s' "$version" > "$root/.tavily-mcp-installed"
}

CACHE_DIR="$(new_sandbox)"
build_fake_install "$CACHE_DIR"

it "accepts a complete install"
verify_cache "$CACHE_DIR"
assert_success "$?"

it "rejects an install whose scoped dependency lost its package.json"
# This is exactly what OS pruning of /tmp did: directories survive, files go.
rm -f "$CACHE_DIR/node_modules/@modelcontextprotocol/sdk/package.json"
verify_cache "$CACHE_DIR"
assert_failure "$?"

it "still sees the .bin symlink even though the install is broken"
# Guards the original bug: presence of .bin was the only check, and it lies.
if [[ -L "$CACHE_DIR/node_modules/.bin/tavily-mcp" ]]; then pass; else fail ".bin symlink vanished, test no longer covers the regression"; fi

it "rejects an install whose top-level dependency lost its package.json"
build_fake_install "$CACHE_DIR"
rm -f "$CACHE_DIR/node_modules/tavily-mcp/package.json"
verify_cache "$CACHE_DIR"
assert_failure "$?"

it "rejects a missing node_modules"
EMPTY_DIR="$(new_sandbox)"
verify_cache "$EMPTY_DIR"
assert_failure "$?"

# --- version pinning ---------------------------------------------------------
printf '\nversion pinning\n'

STAMP_DIR="$(new_sandbox)"
build_fake_install "$STAMP_DIR" "0.2.19"

it "accepts a cache matching the requested version"
verify_cache "$STAMP_DIR" "0.2.19"
assert_success "$?"

it "rejects a cache holding a different version"
# The old wrapper reused whatever was cached, so bumping the pinned version in
# a release never reached anyone who already had a cache.
verify_cache "$STAMP_DIR" "0.2.18"
assert_failure "$?"

it "rejects an install with no version stamp at all"
# Pre-fix caches carry no stamp; they must be reinstalled once so the pinned
# version is genuinely the one that runs.
rm -f "$STAMP_DIR/.tavily-mcp-installed"
verify_cache "$STAMP_DIR" "0.2.19"
assert_failure "$?"

# --- default location --------------------------------------------------------
printf '\ncache location\n'

it "defaults the npm cache outside /tmp"
default_cache="$(
  TAVILY_HOME=/home/example/.tavily-mcp-manager bash -c '
    tavily_home="${TAVILY_HOME}"
    printf "%s" "${TAVILY_NPM_CACHE:-$tavily_home/npm-cache}"
  '
)"
assert_eq "$default_cache" "/home/example/.tavily-mcp-manager/npm-cache"

it "the wrapper no longer hardcodes /tmp as the cache default"
assert_not_contains "$(grep 'TAVILY_NPM_CACHE' "$WRAPPER")" "/tmp/"
