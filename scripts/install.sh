#!/usr/bin/env bash
# install.sh — 服务器一键安装 XCTL Master（curl 入口）
#
# 推荐（兼容 sudo）:
#   curl -fsSL https://raw.githubusercontent.com/catxtom/xctl-publication/main/scripts/install.sh | sudo bash -s -- -install
#
# 或下载后执行:
#   curl -fsSL .../install.sh -o /tmp/xctl-install.sh && sudo bash /tmp/xctl-install.sh -install
#
# 勿用: sudo bash <(curl …)  — sudo 无法传递进程替换的 /dev/fd，会报 No such file or directory
#
# 本地（源码仓）:
#   sudo bash scripts/master/install.sh -install
#
# 环境:
#   XCTL_PUBLICATION_REPO   默认 catxtom/xctl-publication
#   XCTL_SCRIPTS_REF        默认 main

set -eo pipefail

: "${XCTL_PUBLICATION_REPO:=catxtom/xctl-publication}"
: "${XCTL_SCRIPTS_REF:=main}"

_use_local_bundle() {
  [[ -n "${BASH_SOURCE[0]+x}" ]] || return 1
  local src="${BASH_SOURCE[0]}"
  case "$src" in
    -|""|/dev/fd/*|/proc/self/fd/*) return 1 ;;
  esac
  case "$(basename "$src")" in
    bash|sh|dash|zsh) return 1 ;;
  esac
  local dir
  dir="$(cd "$(dirname "$src")" && pwd)" || return 1
  [[ -f "${dir}/xctl-master-install.sh" ]] || return 1
  printf '%s\n' "$dir"
}

_local_dir="$(_use_local_bundle || true)"
if [[ -n "$_local_dir" ]]; then
  exec bash "${_local_dir}/xctl-master-install.sh" "$@"
fi

set -u

if [[ -t 1 && -z "${NO_COLOR:-}" && -z "${XCTL_NO_COLOR:-}" ]]; then
  print_info() { echo -e "\033[0;34m🅸\033[0m $*"; }
else
  print_info() { echo "🅸 $*"; }
fi

_install_i18n() {
  local zh=$1 en=$2
  shift 2
  local lang
  if [[ -z "${XCTL_LANG:-}" && -f /etc/xctl/xctl.lang ]]; then
    XCTL_LANG="$(tr -d '[:space:]' </etc/xctl/xctl.lang)"
  fi
  lang="$(echo "${XCTL_LANG:-en}" | tr '[:upper:]' '[:lower:]')"
  case "$lang" in
    zh|zh_*|zh-*) # shellcheck disable=SC2059
      printf "$zh" "$@" ;;
    *) # shellcheck disable=SC2059
      printf "$en" "$@" ;;
  esac
}

command -v curl >/dev/null || {
  echo "🅴 $(_install_i18n "需要 curl" "curl required")" >&2
  exit 1
}

BASE="https://raw.githubusercontent.com/${XCTL_PUBLICATION_REPO}/${XCTL_SCRIPTS_REF}/scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

print_info "$(_install_i18n "拉取脚本 %s@%s" "Fetching scripts %s@%s" "$XCTL_PUBLICATION_REPO" "$XCTL_SCRIPTS_REF")"
for f in xctl-master-install.sh xctl-banner.sh xctl-messages.sh xctl-messages.en.sh xctl-publication.sh xctl; do
  curl -fsSL "${BASE}/${f}" -o "${TMP}/${f}"
done
chmod +x "${TMP}/xctl-master-install.sh" "${TMP}/xctl"

exec bash "${TMP}/xctl-master-install.sh" "$@"
