#!/usr/bin/env bash
# Behavioural test suite. No external dependencies: bash, node and coreutils
# only, so it runs anywhere the tool itself runs.
#
#   ./tests/run.sh              run everything
#   ./tests/run.sh store cache  run only the named suites

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$TESTS_DIR/helpers.sh"

trap cleanup_sandboxes EXIT

suites=("$@")
if [[ ${#suites[@]} -eq 0 ]]; then
  suites=(store cache rotate install)
fi

for suite in "${suites[@]}"; do
  file="$TESTS_DIR/test_${suite}.sh"
  if [[ ! -f "$file" ]]; then
    printf 'no such suite: %s\n' "$suite" >&2
    exit 2
  fi
  # shellcheck disable=SC1090
  source "$file"
done

summary
