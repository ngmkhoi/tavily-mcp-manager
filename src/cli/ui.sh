#!/usr/bin/env bash

use_color=0
if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
  use_color=1
fi

color() {
  local code="$1"
  if [[ "$use_color" == "1" ]]; then
    printf '\033[%sm' "$code"
  fi
}

reset="$(color 0)"
bold="$(color 1)"
dim="$(color 2)"
green="$(color 32)"
yellow="$(color 33)"
red="$(color 31)"
cyan="$(color 36)"
blue="$(color 34)"

headline() {
  printf '%s\n' "${bold}${cyan}Tavily Manager${reset} ${dim}key rotation for tavily-mcp${reset}"
  printf '%s\n' "${dim}----------------------------------------${reset}"
  printf '\n'
}

section_title() {
  printf '%s%s%s\n' "$bold" "$1" "$reset"
}

ui_kv() {
  local key="$1"
  local value="$2"
  printf '  %s%-13s%s %b\n' "$dim" "$key" "$reset" "$value"
}

ui_status() {
  local label="$1"
  local value="$2"
  local color_value="${3:-$green}"
  printf '  %b%-13s%b %b\n' "$color_value" "$label" "$reset" "${color_value}${value}${reset}"
}

ui_empty() {
  printf '  %s%s%s\n' "$dim" "$1" "$reset"
}

mask_key() {
  local key="$1"
  local prefix="${key:0:14}"
  local suffix="${key: -6}"
  printf '%s...%s' "$prefix" "$suffix"
}
