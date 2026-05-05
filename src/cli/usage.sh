#!/usr/bin/env bash

status_label() {
  local percent="$1"
  local warning="$2"

  if [[ "$percent" == "n/a" ]]; then
    printf '%s' "n/a"
  elif awk "BEGIN { exit !($percent <= $warning) }"; then
    printf '%sLOW%s' "$red" "$reset"
  elif awk "BEGIN { exit !($percent <= 20) }"; then
    printf '%sWATCH%s' "$yellow" "$reset"
  else
    printf '%sOK%s' "$green" "$reset"
  fi
}

status_text() {
  local percent="$1"
  local warning="$2"

  if [[ "$percent" == "n/a" ]]; then
    printf '%s' "n/a"
  elif awk "BEGIN { exit !($percent <= $warning) }"; then
    printf '%s' "LOW"
  elif awk "BEGIN { exit !($percent <= 20) }"; then
    printf '%s' "WATCH"
  else
    printf '%s' "OK"
  fi
}

bar() {
  local percent="$1"
  local width="${2:-18}"

  if [[ "$percent" == "n/a" ]]; then
    printf '%*s' "$width" "" | tr ' ' '-'
    return
  fi

  local filled
  filled="$(awk -v pct="$percent" -v width="$width" 'BEGIN { printf "%d", (pct * width / 100) }')"
  if (( filled < 0 )); then filled=0; fi
  if (( filled > width )); then filled="$width"; fi

  local empty=$((width - filled))
  printf '%*s' "$filled" "" | tr ' ' '#'
  printf '%*s' "$empty" "" | tr ' ' '.'
}

usage_for_key() {
  local id="$1"
  local env_var key label
  env_var="$(key_env_for_id "$id")"
  label="$(key_label_for_id "$id")"
  key="${!env_var:-}"

  if [[ -z "$key" ]]; then
    echo "$id: missing key" >&2
    return 1
  fi

  local curl_args=(
    --fail
    --silent
    --show-error
    --max-time "${TAVILY_USAGE_TIMEOUT_SECONDS:-10}"
    --request GET
    --url "https://api.tavily.com/usage"
    --header "Authorization: Bearer ${key}"
  )

  if [[ -n "${TAVILY_PROJECT_ID:-}" ]]; then
    curl_args+=(--header "X-Project-ID: ${TAVILY_PROJECT_ID}")
  fi

  local response
  if ! response="$(curl "${curl_args[@]}")"; then
    echo "$id: failed to fetch usage" >&2
    return 1
  fi

  TAVILY_USAGE_RESPONSE="$response" node -e '
const data = JSON.parse(process.env.TAVILY_USAGE_RESPONSE || "{}");
const id = process.argv[1];
const label = process.argv[2];
const maskedKey = process.argv[3];
const warningPercent = Number(process.argv[4] || 5);

function number(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function nullableNumber(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function remainingPercent(used, limit) {
  if (!limit) return null;
  return Math.max(0, ((limit - used) / limit) * 100);
}

function rawPercent(value) {
  return value === null ? "n/a" : value.toFixed(1);
}

function recordFor(scope, used, limit) {
  if (limit === null) {
    return { scope, used, limit: "n/a", remaining: "n/a", percent: "n/a", warning: false };
  }
  const remaining = Math.max(0, limit - used);
  const percent = remainingPercent(used, limit);
  return {
    scope,
    used,
    limit,
    remaining,
    percent: rawPercent(percent),
    warning: percent !== null && percent <= warningPercent
  };
}

const key = data.key || {};
const account = data.account || {};
const keyUsed = number(key.usage);
const keyLimit = nullableNumber(key.limit);
const planUsed = number(account.plan_usage);
const planLimit = number(account.plan_limit);
const paygoUsed = number(account.paygo_usage);
const paygoLimit = number(account.paygo_limit);
const accountUsed = planUsed + paygoUsed;
const accountLimit = planLimit + paygoLimit;

const keyTotal = recordFor("key", keyUsed, keyLimit);
const accountTotal = recordFor("account", accountUsed, accountLimit);
const rows = [
  `META|${id}|${label}|${maskedKey}|${account.current_plan || "unknown"}|${warningPercent}`,
  `ROW|${keyTotal.scope}|${keyTotal.used}|${keyTotal.limit}|${keyTotal.remaining}|${keyTotal.percent}|${keyTotal.warning ? "1" : "0"}`,
  `BREAKDOWN|key|${number(key.search_usage)}|${number(key.extract_usage)}|${number(key.crawl_usage)}|${number(key.map_usage)}|${number(key.research_usage)}`
];

if (accountLimit || account.current_plan) {
  rows.push(
    `ROW|${accountTotal.scope}|${accountTotal.used}|${accountTotal.limit}|${accountTotal.remaining}|${accountTotal.percent}|${accountTotal.warning ? "1" : "0"}`,
    `BREAKDOWN|account|${number(account.search_usage)}|${number(account.extract_usage)}|${number(account.crawl_usage)}|${number(account.map_usage)}|${number(account.research_usage)}`
  );
}

console.log(rows.join("\n"));
' "$id" "$label" "$(mask_key "$key")" "${TAVILY_USAGE_WARNING_PERCENT:-5}"
}

render_usage() {
  local raw="$1"
  local show_headline="${2:-1}"
  local warning_percent="${TAVILY_USAGE_WARNING_PERCENT:-5}"
  local key_id=""
  local label=""
  local masked=""
  local plan=""
  local rows=()
  local breakdowns=()
  local line

  while IFS= read -r line; do
    IFS='|' read -r type c1 c2 c3 c4 c5 c6 _ <<<"$line"
    case "$type" in
      META)
        key_id="$c1"
        label="$c2"
        masked="$c3"
        plan="$c4"
        warning_percent="$c5"
        ;;
      ROW)
        rows+=("$c1|$c2|$c3|$c4|$c5|$c6")
        ;;
      BREAKDOWN)
        breakdowns+=("$c1|$c2|$c3|$c4|$c5|$c6")
        ;;
    esac
  done <<<"$raw"

  if [[ "$show_headline" == "1" ]]; then
    headline
  fi

  section_title "$(key_title "$key_id" "$label")"
  ui_kv "api key" "$masked"
  ui_kv "plan" "$plan"
  ui_kv "warn at" "<= ${warning_percent}% remaining"
  printf '\n'

  printf '%-10s %9s %9s %9s %9s %-20s %s\n' "Scope" "Used" "Limit" "Remain" "Left" "Credits" "Status"
  printf '%-10s %9s %9s %9s %9s %-20s %s\n' "----------" "---------" "---------" "---------" "---------" "------------------" "------"

  local row scope used limit remaining percent warn status percent_text
  for row in "${rows[@]}"; do
    IFS='|' read -r scope used limit remaining percent warn <<<"$row"
    status="$(status_label "$percent" "$warning_percent")"
    if [[ "$percent" == "n/a" ]]; then
      percent_text="n/a"
    else
      percent_text="${percent}%"
    fi
    printf '%-10s %9s %9s %9s %9s [%s] %b\n' "$scope" "$used" "$limit" "$remaining" "$percent_text" "$(bar "$percent")" "$status"
  done

  printf '\n'
  section_title "Breakdown"
  printf '%-10s %9s %9s %9s %9s %9s\n' "Scope" "Search" "Extract" "Crawl" "Map" "Research"
  printf '%-10s %9s %9s %9s %9s %9s\n' "----------" "---------" "---------" "---------" "---------" "---------"

  local breakdown search extract crawl map research
  for breakdown in "${breakdowns[@]}"; do
    IFS='|' read -r scope search extract crawl map research <<<"$breakdown"
    printf '%-10s %9s %9s %9s %9s %9s\n' "$scope" "$search" "$extract" "$crawl" "$map" "$research"
  done
}

candidate_for_raw_usage() {
  local raw="$1"
  local key_id=""
  local label=""
  local masked=""
  local key_row=""
  local account_row=""
  local line

  while IFS= read -r line; do
    IFS='|' read -r type c1 c2 c3 c4 c5 c6 _ <<<"$line"
    case "$type" in
      META)
        key_id="$c1"
        label="$c2"
        masked="$c3"
        ;;
      ROW)
        if [[ "$c1" == "key" ]]; then
          key_row="$c1|$c2|$c3|$c4|$c5"
        elif [[ "$c1" == "account" ]]; then
          account_row="$c1|$c2|$c3|$c4|$c5"
        fi
        ;;
    esac
  done <<<"$raw"

  local selected="$key_row"
  if [[ -z "$selected" || "$selected" == *"|n/a" ]]; then
    selected="$account_row"
  fi

  if [[ -z "$selected" ]]; then
    return 1
  fi

  local scope used limit remaining percent
  IFS='|' read -r scope used limit remaining percent <<<"$selected"
  if [[ "$percent" == "n/a" ]]; then
    return 1
  fi

  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$key_id" "$percent" "$scope" "$used" "$limit" "$remaining" "$masked" "$label"
}

usage_summary_row() {
  local raw="$1"
  local candidate
  candidate="$(candidate_for_raw_usage "$raw")" || return 1

  local key_id percent scope used limit remaining masked label status percent_text
  IFS='|' read -r key_id percent scope used limit remaining masked label <<<"$candidate"
  status="$(status_text "$percent" "${TAVILY_USAGE_WARNING_PERCENT:-5}")"
  percent_text="${percent}%"
  printf '%-16s %-9s %8s %8s %8s %8s %b\n' "$(key_title "$key_id" "$label")" "$scope" "$used" "$limit" "$remaining" "$percent_text" "$status"
}

rotate_key() {
  local dry_run=0
  local min_remaining="${TAVILY_ROTATE_THRESHOLD_PERCENT:-${TAVILY_USAGE_WARNING_PERCENT:-5}}"
  local only_if_current_below=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=1
        shift
        ;;
      --min-remaining)
        min_remaining="${2:-}"
        if [[ -z "$min_remaining" ]]; then
          usage
          exit 2
        fi
        shift 2
        ;;
      --only-if-current-below)
        only_if_current_below="${2:-}"
        if [[ -z "$only_if_current_below" ]]; then
          usage
          exit 2
        fi
        shift 2
        ;;
      *)
        usage
        exit 2
        ;;
    esac
  done

  local current
  current="$(current_id)"
  local best=""
  local current_candidate=""
  local candidates=()
  local id raw candidate percent

  while IFS='|' read -r id _ _; do
    if [[ -z "$(key_for_id "$id")" ]]; then
      continue
    fi
    if raw="$(usage_for_key "$id" 2>/dev/null)" && candidate="$(candidate_for_raw_usage "$raw")"; then
      candidates+=("$candidate")
      if [[ "$id" == "$current" ]]; then
        current_candidate="$candidate"
      fi
      IFS='|' read -r _ percent _ <<<"$candidate"
      if [[ -z "$best" ]]; then
        best="$candidate"
      else
        local best_percent
        IFS='|' read -r _ best_percent _ <<<"$best"
        if awk "BEGIN { exit !($percent > $best_percent) }"; then
          best="$candidate"
        fi
      fi
    fi
  done < <(store list)

  if [[ -z "$best" ]]; then
    echo "No usable Tavily keys found for rotation." >&2
    exit 1
  fi

  local best_id best_percent best_scope best_used best_limit best_remaining best_masked best_label
  IFS='|' read -r best_id best_percent best_scope best_used best_limit best_remaining best_masked best_label <<<"$best"

  if [[ -n "$only_if_current_below" && -n "$current_candidate" ]]; then
    local current_percent
    IFS='|' read -r _ current_percent _ <<<"$current_candidate"
    if awk "BEGIN { exit !($current_percent >= $only_if_current_below) }"; then
      headline
      ui_status "skipped" "active key #$current is above threshold" "$yellow"
      ui_kv "remaining" "${current_percent}%"
      ui_kv "threshold" "${only_if_current_below}%"
      exit 0
    fi
  fi

  headline
  if [[ "$dry_run" == "1" ]]; then
    ui_status "dry run" "#$current -> $(key_title "$best_id" "$best_label")" "$yellow"
  else
    if awk "BEGIN { exit !($best_percent < $min_remaining) }"; then
      ui_status "skipped" "best key below minimum" "$yellow"
      ui_kv "best key" "$(key_title "$best_id" "$best_label")"
      ui_kv "remaining" "${best_percent}%"
      ui_kv "minimum" "${min_remaining}%"
      exit 1
    fi
    store switch "$best_id" >/dev/null
    ui_status "active" "$(key_title "$best_id" "$best_label")"
    ui_kv "api key" "$best_masked"
  fi

  ui_kv "strategy" "most-remaining"
  ui_kv "scope" "$best_scope"
  ui_kv "remaining" "$best_remaining/$best_limit (${best_percent}%)"
  ui_kv "minimum" "${min_remaining}%"
  printf '\n'
  section_title "Candidates"
  printf '%-16s %-9s %-10s %-9s %-9s %s\n' "Key" "Left" "Scope" "Used" "Limit" "API key"
  printf '%-16s %-9s %-10s %-9s %-9s %s\n' "--------------" "---------" "----------" "---------" "---------" "------------------------"

  local row row_id row_percent row_scope row_used row_limit row_remaining row_masked row_label marker
  for row in "${candidates[@]}"; do
    IFS='|' read -r row_id row_percent row_scope row_used row_limit row_remaining row_masked row_label <<<"$row"
    marker="$(key_title "$row_id" "$row_label")"
    [[ "$row_id" == "$best_id" ]] && marker=">${marker}"
    printf '%-16s %-9s %-10s %-9s %-9s %s\n' "$marker" "${row_percent}%" "$row_scope" "$row_used" "$row_limit" "$row_masked"
  done
}
