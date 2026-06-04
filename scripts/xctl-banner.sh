#!/usr/bin/env bash
# XCTL 终端 UI — install / xctl / 运维菜单共用（风格对齐 FF1 Panel）

_xctl_color_enabled() {
  [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ -z "${XCTL_NO_COLOR:-}" ]]
}

_xctl_init_ui_colors() {
  if _xctl_color_enabled; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    NC=$'\033[0m'
  else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    NC=""
  fi
}

_xctl_init_ui_colors

# 语言：默认 en；优先 XCTL_LANG 环境变量，其次 XCTL_LANG_FILE（如 /etc/xctl/xctl.lang）
: "${XCTL_LANG_FILE:=/etc/xctl/xctl.lang}"

_xctl_normalize_lang() {
  local l
  l="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  case "$l" in
    zh|zh_*|zh-*) echo zh ;;
    en|en_*|en-*) echo en ;;
    *) echo en ;;
  esac
}

_xctl_load_lang_pref() {
  if [[ -n "${XCTL_LANG:-}" ]]; then
    _xctl_normalize_lang "$XCTL_LANG"
    return
  fi
  if [[ -f "$XCTL_LANG_FILE" ]]; then
    local saved
    saved="$(tr -d '[:space:]' <"$XCTL_LANG_FILE" 2>/dev/null || true)"
    if [[ -n "$saved" ]]; then
      _xctl_normalize_lang "$saved"
      return
    fi
  fi
  echo en
}

_xctl_save_lang() {
  local lang
  lang="$(_xctl_normalize_lang "$1")"
  mkdir -p "$(dirname "$XCTL_LANG_FILE")" 2>/dev/null || true
  echo "$lang" >"$XCTL_LANG_FILE"
  chmod 644 "$XCTL_LANG_FILE" 2>/dev/null || true
  export XCTL_LANG="$lang"
  _xctl_init_lang
}

_xctl_init_lang() {
  local lang dir
  lang="$(_xctl_load_lang_pref)"
  export XCTL_LANG="$lang"
  export XCTL_LANG_RESOLVED="$lang"
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ "$lang" == zh && -f "${dir}/xctl-messages.sh" ]]; then
    # shellcheck disable=SC1091
    source "${dir}/xctl-messages.sh"
  elif [[ -f "${dir}/xctl-messages.en.sh" ]]; then
    # shellcheck disable=SC1091
    source "${dir}/xctl-messages.en.sh"
  else
    # shellcheck disable=SC1091
    source "${dir}/xctl-messages.sh"
  fi
}

_xctl_lang_display_name() {
  case "$(_xctl_normalize_lang "${1:-$XCTL_LANG_RESOLVED}")" in
    zh) _xctl_msg lang_name_zh ;;
    *) _xctl_msg lang_name_en ;;
  esac
}

_xctl_lang_menu() {
  local choice
  clear
  print_divider
  echo
  echo "  $(_xctl_msg lang_menu_title)"
  print_divider
  echo
  echo -e "${GREEN}1.${NC}  $(_xctl_msg lang_pick_en)"
  echo -e "${GREEN}2.${NC}  $(_xctl_msg lang_pick_zh)"
  echo -e "${GREEN}0.${NC}  $(_xctl_msg lang_back)"
  print_divider
  echo
  prompt_read -p "$(_xctl_msg lang_prompt_choice)" choice
  case "$choice" in
    1)
      _xctl_save_lang en
      print_success "$(_xctl_msg ok_lang "$(_xctl_lang_display_name en)")"
      ;;
    2)
      _xctl_save_lang zh
      print_success "$(_xctl_msg ok_lang "$(_xctl_lang_display_name zh)")"
      ;;
    0|"") ;;
    *)
      print_warn "$(_xctl_msg warn_bad_choice)"
      ;;
  esac
}

# shellcheck disable=SC2059
_xctl_msg() {
  local key=$1
  shift
  local var="XCTL_MSG_${key}"
  local fmt="${!var:-${key}}"
  printf "$fmt" "$@"
}

_xctl_init_lang

print_info() {
  echo -e "${BLUE}🅸${NC} $*"
}

print_warn() {
  echo -e "${YELLOW}🆆${NC} $*"
}

print_error() {
  echo -e "${RED}🅴${NC} $*" >&2
}

print_success() {
  echo -e "${GREEN}🆂${NC} $*"
}

print_divider() {
  echo -e "${BLUE}▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃${NC}"
}

print_menu_sep() {
  echo -e "${YELLOW}———————————————————————————————————${NC}"
}

print_xctl_banner() {
  local c="${XCTL_BANNER_COLOR:-$BLUE}"
  local nc="${XCTL_BANNER_NC:-$NC}"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$c" || -n "$nc" ]]; then
      printf '%b%s%b\n' "$c" "$line" "$nc"
    else
      printf '%s\n' "$line"
    fi
  done <<'EOF'
 █████ █████   █████████  ███████████ █████      
░░███ ░░███   ███░░░░░███░█░░░███░░░█░░███       
 ░░███ ███   ███     ░░░ ░   ░███  ░  ░███       
  ░░█████   ░███             ░███     ░███       
   ███░███  ░███             ░███     ░███       
  ███ ░░███ ░░███     ███    ░███     ░███      █
 █████ █████ ░░█████████     █████    ███████████
░░░░░ ░░░░░   ░░░░░░░░░     ░░░░░    ░░░░░░░░░░░
EOF
}

print_install_header() {
  local title="${1:-$(_xctl_msg hdr_install)}"
  echo
  print_xctl_banner
  print_divider
  echo
  echo -e "  ${title}"
  print_divider
  echo
}

print_section_header() {
  local title="${1:-}"
  echo
  print_divider
  echo
  [[ -n "$title" ]] && echo -e "  ${title}"
  [[ -n "$title" ]] && echo
  print_divider
  echo
}
