#!/usr/bin/env bash
# xctl-master-install.sh — XCTL Master 生产安装 / 运维菜单
#
# 用法:
#   bash scripts/master/xctl-master-install.sh          # 交互菜单
#   bash scripts/master/xctl-master-install.sh -install   # 非交互全新安装（需 root）
#   LOCAL_PACKAGE=dist/xctlmaster-linux-amd64-latest.tar.gz bash ... -install
#
# 下载地址（默认 GitHub Releases rolling tag master-latest）:
#   仓库: XCTL_PUBLICATION_REPO=catxtom/xctl-publication
#   覆盖: XCTL_MASTER_AMD64_URL / XCTL_MASTER_ARM64_URL
#   本地: LOCAL_PACKAGE=dist/xctlmaster-linux-amd64-latest.tar.gz

set -euo pipefail

SCRIPT_VERSION="1.0.0"

INSTALL_DIR="/etc/xctl"
MASTER_DIR="${INSTALL_DIR}/master"
ENV_FILE="${INSTALL_DIR}/master.env"
ADMIN_CREDS_FILE="${INSTALL_DIR}/admin.credentials"
SYSTEMD_UNIT="xctl-master.service"
PACKAGE_PREFIX="xctlmaster"
TEMP_DIR="/tmp/xctl-master-install"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export XCTL_LANG_FILE="${INSTALL_DIR}/xctl.lang"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/xctl-banner.sh"
if [[ -f "${SCRIPT_DIR}/xctl-publication.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/xctl-publication.sh"
elif [[ -f "${SCRIPT_DIR}/../lib/xctl-publication.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/../lib/xctl-publication.sh"
else
  echo "$(_xctl_msg err_pub_missing)" >&2
  exit 1
fi

AMD64_DOWNLOAD_URL="${XCTL_MASTER_AMD64_URL:-${XUICTL_MASTER_AMD64_URL:-$(master_package_url amd64)}}"
ARM64_DOWNLOAD_URL="${XCTL_MASTER_ARM64_URL:-${XUICTL_MASTER_ARM64_URL:-$(master_package_url arm64)}}"
LOCAL_PACKAGE="${LOCAL_PACKAGE:-}"

# curl | bash 时 stdin 是脚本内容；交互安装需读 /dev/tty
prompt_read() {
  if [[ -r /dev/tty ]]; then
    read -r "$@" </dev/tty
  else
    read -r "$@"
  fi
}

prompt_read_secret() {
  if [[ -r /dev/tty ]]; then
    read -r -s "$@" </dev/tty
    echo >&2
  else
    read -r -s "$@"
    echo
  fi
}

prompt_pause() {
  if [[ -r /dev/tty ]]; then
    read -r -p "$1" _ </dev/tty
  else
    read -r -p "$1" _
  fi
}

# copy_file_unless_same 避免从 /etc/xctl 自升级时 cp 源=目标（set -e 会中断）。
copy_file_unless_same() {
  local src="$1" dst="$2"
  [[ -f "$src" ]] || return 0
  local a b
  a="$(readlink -f "$src" 2>/dev/null || echo "$src")"
  b="$(readlink -f "$dst" 2>/dev/null || echo "$dst")"
  if [[ "$a" == "$b" ]]; then
    return 0
  fi
  cp "$src" "$dst"
}

check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    print_error "$(_xctl_msg err_need_root "$0")"
    exit 1
  fi
}

check_architecture() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
      print_error "$(_xctl_msg err_arch "$arch")"
      exit 1
      ;;
  esac
  print_info "$(_xctl_msg info_arch "$ARCH")"
}

check_systemd() {
  command -v systemctl >/dev/null || {
    print_error "$(_xctl_msg err_systemd)"
    exit 1
  }
}

generate_random_string() {
  local length=$1
  local charset="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  local result="" i
  for ((i = 0; i < length; i++)); do
    result="${result}${charset:RANDOM%${#charset}:1}"
  done
  echo "$result"
}

generate_username() { generate_random_string 8; }
generate_password() { generate_random_string 16; }

create_temp_dir() {
  # 每次安装/升级前清空，避免旧 tarball 解压残留（如已 squash 删掉的 002_*.sql）
  # 被 tar 合并进 pkg_dir 后 cp 到 /etc/xctl/master/migrations。
  rm -rf "$TEMP_DIR"
  mkdir -p "$TEMP_DIR"
}

cleanup_temp_dir() {
  [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}

port_in_use() {
  local port=$1
  if command -v ss >/dev/null; then
    ss -tuln | grep -q ":${port} "
  elif command -v netstat >/dev/null; then
    netstat -tuln | grep -q ":${port} "
  else
    return 1
  fi
}

get_server_ips() {
  local ips=() line
  if command -v ip >/dev/null; then
    while IFS= read -r line; do
      if [[ $line =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] &&
        [[ ! $line =~ ^127\. ]] &&
        [[ ! $line =~ ^169\.254\. ]]; then
        ips+=("$line")
      fi
    done < <(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | sort -u)
  fi
  if [[ ${#ips[@]} -eq 0 ]]; then
    ips=("127.0.0.1")
  fi
  printf '%s\n' "${ips[@]}"
}

ensure_master_key() {
  if [[ -f "$ENV_FILE" ]] && grep -q '^MWAAS_MASTER_KEY=' "$ENV_FILE"; then
    print_info "$(_xctl_msg info_keep_key)"
    return
  fi
  local key
  key="$(openssl rand -base64 32)"
  mkdir -p "$INSTALL_DIR"
  {
    echo "# XCTL Master 运行时环境（systemd EnvironmentFile）"
    echo "MWAAS_MASTER_KEY=${key}"
  } >>"$ENV_FILE"
  chmod 600 "$ENV_FILE"
  print_success "$(_xctl_msg ok_key_generated "$ENV_FILE")"
}

write_env_file() {
  mkdir -p "$INSTALL_DIR"
  local license_key="${LICENSE_KEY:-}"
  local tmp
  tmp="$(mktemp)"
  if [[ -f "$ENV_FILE" ]]; then
    grep -v -E '^(XCTL_LICENSE_KEY|XUICTL_LICENSE_KEY|XUICTL_CLIENT_BIN_DIR|XCTL_PUBLICATION_REPO)=' "$ENV_FILE" >"$tmp" || true
  fi
  {
    cat "$tmp" 2>/dev/null || true
    [[ -n "$license_key" ]] && echo "XCTL_LICENSE_KEY=${license_key}"
    echo "XUICTL_CLIENT_BIN_DIR=${MASTER_DIR}/dl"
    echo "XCTL_PUBLICATION_REPO=${XCTL_PUBLICATION_REPO}"
  } >"$ENV_FILE"
  rm -f "$tmp"
  chmod 600 "$ENV_FILE"
}

get_user_input() {
  LICENSE_KEY="${XCTL_LICENSE_KEY:-${XUICTL_LICENSE_KEY:-${LICENSE_KEY:-}}}"
  MASTER_PORT="${XUICTL_MASTER_PORT:-${MASTER_PORT:-80}}"
  DB_HOST="${XUICTL_DB_HOST:-${DB_HOST:-127.0.0.1}}"
  DB_PORT="${XUICTL_DB_PORT:-${DB_PORT:-3306}}"
  DB_NAME="${XUICTL_DB_NAME:-${DB_NAME:-xctl}}"
  DB_USER="${XUICTL_DB_USER:-${DB_USER:-xctl}}"
  DB_PASS="${XUICTL_DB_PASS:-${DB_PASS:-}}"

  if [[ -n "$LICENSE_KEY" && -n "${DATABASE_DSN:-}" ]]; then
    print_info "$(_xctl_msg info_env_dsn)"
    return
  fi
  if [[ -n "$LICENSE_KEY" && -n "$DB_PASS" ]]; then
    DATABASE_DSN="${DB_USER}:${DB_PASS}@tcp(${DB_HOST}:${DB_PORT})/${DB_NAME}?charset=utf8mb4&parseTime=True&loc=UTC"
    print_info "$(_xctl_msg info_env_db)"
    return
  fi

  print_info "$(_xctl_msg info_config_prompt)"
  echo

  while true; do
    prompt_read -p "$(_xctl_msg prompt_license)" LICENSE_KEY
    [[ -n "$LICENSE_KEY" ]] && break
    print_warn "$(_xctl_msg warn_license_empty)"
  done

  while true; do
    prompt_read -p "$(_xctl_msg prompt_port)" MASTER_PORT
    MASTER_PORT="${MASTER_PORT:-80}"
    if [[ "$MASTER_PORT" =~ ^[0-9]+$ ]] && ((MASTER_PORT >= 1 && MASTER_PORT <= 65535)); then
      if port_in_use "$MASTER_PORT"; then
        print_warn "$(_xctl_msg warn_port_used "$MASTER_PORT")"
        continue
      fi
      break
    fi
    print_warn "$(_xctl_msg warn_port_invalid)"
  done

  print_menu_sep
  print_info "$(_xctl_msg info_mariadb)"
  echo

  prompt_read -p "$(_xctl_msg prompt_db_host)" DB_HOST
  DB_HOST="${DB_HOST:-127.0.0.1}"
  prompt_read -p "$(_xctl_msg prompt_db_port)" DB_PORT
  DB_PORT="${DB_PORT:-3306}"
  prompt_read -p "$(_xctl_msg prompt_db_name)" DB_NAME
  DB_NAME="${DB_NAME:-xctl}"
  prompt_read -p "$(_xctl_msg prompt_db_user)" DB_USER
  DB_USER="${DB_USER:-xctl}"
  while true; do
    prompt_read_secret -p "$(_xctl_msg prompt_db_pass)" DB_PASS
    [[ -n "$DB_PASS" ]] && break
    print_warn "$(_xctl_msg warn_pass_empty)"
  done

  DATABASE_DSN="${DB_USER}:${DB_PASS}@tcp(${DB_HOST}:${DB_PORT})/${DB_NAME}?charset=utf8mb4&parseTime=True&loc=UTC"
  print_success "$(_xctl_msg ok_config_done)"
}

create_directories() {
  print_info "$(_xctl_msg info_mkdir)"
  mkdir -p "${MASTER_DIR}/configs" "${MASTER_DIR}/dl"
  print_success "$(_xctl_msg ok_mkdir)"
}

resolve_download_url() {
  if [[ -n "$LOCAL_PACKAGE" ]]; then
    echo "local"
    return
  fi
  if [[ "$ARCH" == "amd64" && -n "$AMD64_DOWNLOAD_URL" ]]; then
    echo "$AMD64_DOWNLOAD_URL"
  elif [[ "$ARCH" == "arm64" && -n "$ARM64_DOWNLOAD_URL" ]]; then
    echo "$ARM64_DOWNLOAD_URL"
  else
    echo ""
  fi
}

install_master_package() {
  create_temp_dir
  local url pkg_dir stage
  url="$(resolve_download_url)"

  if [[ "$url" == "local" ]]; then
    [[ -f "$LOCAL_PACKAGE" ]] || {
      print_error "$(_xctl_msg err_local_pkg "$LOCAL_PACKAGE")"
      exit 1
    }
    print_info "$(_xctl_msg info_local_pkg "$LOCAL_PACKAGE")"
    cp "$LOCAL_PACKAGE" "${TEMP_DIR}/${PACKAGE_PREFIX}.tar.gz"
  elif [[ -z "$url" ]]; then
    print_error "$(_xctl_msg err_no_url "${ARCH^^}")"
    exit 1
  else
    print_info "$(_xctl_msg info_download "$ARCH")"
    curl -fLk -o "${TEMP_DIR}/${PACKAGE_PREFIX}.tar.gz" "$url" || {
      print_error "$(_xctl_msg err_download "$url")"
      exit 1
    }
  fi

  print_info "$(_xctl_msg info_extract)"
  tar -xzf "${TEMP_DIR}/${PACKAGE_PREFIX}.tar.gz" -C "$TEMP_DIR"
  pkg_dir="${TEMP_DIR}/${PACKAGE_PREFIX}-linux-${ARCH}"
  [[ -d "$pkg_dir" ]] || {
    print_error "$(_xctl_msg err_pkg_layout "$PACKAGE_PREFIX" "$ARCH")"
    exit 1
  }
  [[ -f "${pkg_dir}/xctl-master" ]] || {
    print_error "$(_xctl_msg err_pkg_binary)"
    exit 1
  }

  cp -f "${pkg_dir}/xctl-master" "${MASTER_DIR}/"
  chmod +x "${MASTER_DIR}/xctl-master"
  ln -sf "${MASTER_DIR}/xctl-master" /usr/local/bin/xctl-master

  [[ -d "${pkg_dir}/web" ]] && cp -R "${pkg_dir}/web" "${MASTER_DIR}/"
  [[ -d "${pkg_dir}/dl" ]] && cp -R "${pkg_dir}/dl/." "${MASTER_DIR}/dl/"
  # migrations：整目录替换而非合并，避免历次发版（如 squash 合并）残留的孤儿 .sql
  # 仍被 migrate runner 扫描执行（例如已删除的 002_*）。迁移由 history 表幂等跟踪，安全。
  if [[ -d "${pkg_dir}/migrations" ]]; then
    rm -rf "${MASTER_DIR}/migrations"
    cp -R "${pkg_dir}/migrations" "${MASTER_DIR}/"
  fi
  [[ -f "${pkg_dir}/start.sh" ]] && cp "${pkg_dir}/start.sh" "${MASTER_DIR}/" && chmod +x "${MASTER_DIR}/start.sh"

  if [[ -d "${pkg_dir}/scripts" ]]; then
    export XCTL_INSTALL_PKG_DIR="${pkg_dir}/scripts"
  else
    unset XCTL_INSTALL_PKG_DIR
  fi

  print_success "$(_xctl_msg ok_installed "$MASTER_DIR")"
}

generate_config() {
  print_info "$(_xctl_msg info_gen_config)"
  ADMIN_USERNAME="$(generate_username)"
  ADMIN_PASSWORD="$(generate_password)"

  cat >"${MASTER_DIR}/configs/master.yaml" <<EOF
server:
  host: "0.0.0.0"
  port: ${MASTER_PORT}
  read_timeout: 30s
  write_timeout: 0s
  shutdown_timeout: 30s
  use_tls: false
  tls_cert: ""
  tls_key: ""

database:
  driver: "mysql"
  dsn: "${DATABASE_DSN}"
  max_open_conns: 20
  max_idle_conns: 5
  conn_max_lifetime: 30m
  auto_migrate: true
  migrations_path: "migrations"

master:
  feature:
    modeA_enabled: false
    modeB_enabled: true

panel:
  enabled: true

logging:
  level: "info"
  http_style: "structured"
  format: "json"
  file: ""

observability:
  prom_bind: ":9100"

security:
  cors:
    enabled: true
    allow_all: false
    allowed_origins: []
EOF
  chmod 600 "${MASTER_DIR}/configs/master.yaml"

  ensure_master_key
  write_env_file

  umask 077
  cat >"$ADMIN_CREDS_FILE" <<EOF
username=${ADMIN_USERNAME}
password=${ADMIN_PASSWORD}
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 600 "$ADMIN_CREDS_FILE"
  print_success "$(_xctl_msg ok_config)"
}

create_systemd_service() {
  print_info "$(_xctl_msg info_systemd)"
  cat >"/etc/systemd/system/${SYSTEMD_UNIT}" <<EOF
[Unit]
Description=XCTL Master (MWaaS)
After=network-online.target mariadb.service mysql.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${MASTER_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${MASTER_DIR}/xctl-master --config configs/master.yaml
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "${SYSTEMD_UNIT}"
  print_success "$(_xctl_msg ok_systemd "$SYSTEMD_UNIT")"
}

bootstrap_admin() {
  print_info "$(_xctl_msg info_bootstrap)"
  (
    cd "$MASTER_DIR"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
    ./xctl-master --config configs/master.yaml -u "$ADMIN_USERNAME" -p "$ADMIN_PASSWORD"
  )
  print_success "$(_xctl_msg ok_bootstrap)"
}

start_service() {
  print_info "$(_xctl_msg info_start)"
  if systemctl is-active --quiet "${SYSTEMD_UNIT}" 2>/dev/null; then
    systemctl restart "${SYSTEMD_UNIT}"
  else
    systemctl start "${SYSTEMD_UNIT}"
  fi
  sleep 2
  if systemctl is-active --quiet "${SYSTEMD_UNIT}"; then
    print_success "$(_xctl_msg ok_started)"
  else
    print_error "$(_xctl_msg err_start_failed "$SYSTEMD_UNIT")"
    exit 1
  fi
}

install_xctl_command() {
  print_info "$(_xctl_msg info_install_xctl)"
  local src_dir f
  src_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  if [[ -n "${XCTL_INSTALL_PKG_DIR:-}" && -f "${XCTL_INSTALL_PKG_DIR}/xctl-master-install.sh" ]]; then
    src_dir="${XCTL_INSTALL_PKG_DIR}"
    print_info "$(_xctl_msg info_scripts_from_pkg "$INSTALL_DIR")"
  fi
  if [[ -f "${src_dir}/xctl" ]]; then
    copy_file_unless_same "${src_dir}/xctl" /usr/local/bin/xctl
    chmod +x /usr/local/bin/xctl
    print_success "$(_xctl_msg ok_xctl_cmd)"
  fi
  for f in xctl-master-install.sh xctl-banner.sh xctl-messages.sh xctl-messages.en.sh xctl-publication.sh; do
    [[ -f "${src_dir}/${f}" ]] || continue
    copy_file_unless_same "${src_dir}/${f}" "${INSTALL_DIR}/${f}"
  done
  chmod +x "${INSTALL_DIR}/xctl-master-install.sh" 2>/dev/null || true
}

show_completion_info() {
  print_section_header "$(_xctl_msg hdr_done)"

  print_info "$(_xctl_msg info_urls)"
  echo "———————————————————————————————————"
  echo "$(_xctl_msg hint_origin)"
  echo
  while IFS= read -r ip; do
    echo "  http://${ip}:${MASTER_PORT}/"
  done < <(get_server_ips)
  echo "———————————————————————————————————"
  echo

  if [[ -f "$ADMIN_CREDS_FILE" ]]; then
    print_warn "$(_xctl_msg warn_save_creds)"
    print_info "$(_xctl_msg info_creds_cmd)"
    echo "———————————————————————————————————"
    # shellcheck disable=SC1090
    source "$ADMIN_CREDS_FILE"
    echo "$(_xctl_msg lbl_user): ${username:-}"
    echo "$(_xctl_msg lbl_pass): ${password:-}"
    echo "———————————————————————————————————"
    echo
  fi

  print_info "$(_xctl_msg info_paths)"
  echo "  $(_xctl_msg lbl_install_dir): ${INSTALL_DIR}"
  echo "  $(_xctl_msg lbl_config): ${MASTER_DIR}/configs/master.yaml"
  echo "  $(_xctl_msg lbl_env): ${ENV_FILE}"
  echo "  $(_xctl_msg lbl_creds): ${ADMIN_CREDS_FILE}"
  echo

  print_info "$(_xctl_msg info_svc_cmds)"
  echo "  $(_xctl_msg svc_start): systemctl start ${SYSTEMD_UNIT}"
  echo "  $(_xctl_msg svc_stop): systemctl stop ${SYSTEMD_UNIT}"
  echo "  $(_xctl_msg svc_restart): systemctl restart ${SYSTEMD_UNIT}"
  echo "  $(_xctl_msg svc_status): systemctl status ${SYSTEMD_UNIT}"
  echo "  $(_xctl_msg svc_logs): journalctl -u ${SYSTEMD_UNIT} -f"
  echo

  print_info "$(_xctl_msg info_cmds)"
  echo "  $(_xctl_msg cmd_menu)"
  echo "  $(_xctl_msg cmd_creds)"
  echo
  if declare -F print_master_install_hints >/dev/null 2>&1; then
    print_master_install_hints
  fi
}

do_install() {
  print_install_header "$(_xctl_msg hdr_install)"
  check_root
  check_architecture
  check_systemd
  get_user_input
  create_directories
  install_master_package
  generate_config
  create_systemd_service
  bootstrap_admin
  install_xctl_command
  start_service
  cleanup_temp_dir
  show_completion_info
}

# do_upgrade：仅替换二进制 / web / dl / migrations 并重启，保留 master.yaml / env / 数据库。
# 供 Web 端「升级 Master」与 `xctl master upgrade` 复用（非交互、幂等、不重置凭据）。
do_upgrade() {
  export XCTL_NO_COLOR=1
  if [[ -f "${INSTALL_DIR}/xctl-publication.sh" ]]; then
    # shellcheck disable=SC1091
    source "${INSTALL_DIR}/xctl-publication.sh"
    sync_xctl_ui_scripts "${INSTALL_DIR}" "${INSTALL_DIR}" || true
  fi
  print_install_header "$(_xctl_msg hdr_upgrade)"
  check_root
  check_architecture
  if [[ ! -d "$MASTER_DIR" || ! -f "${MASTER_DIR}/xctl-master" ]]; then
    print_error "$(_xctl_msg err_not_installed "$MASTER_DIR")"
    exit 1
  fi
  install_master_package
  install_xctl_command
  print_info "$(_xctl_msg info_restart_unit "$SYSTEMD_UNIT")"
  systemctl daemon-reload 2>/dev/null || true
  systemctl restart "${SYSTEMD_UNIT}"
  cleanup_temp_dir
  print_success "$(_xctl_msg ok_upgrade)"
}

show_menu() {
  clear
  print_divider
  echo
  echo "  $(_xctl_msg menu_title)"
  print_xctl_banner
  print_divider
  echo
  echo -e "${GREEN}1.${NC}  $(_xctl_msg m1)"
  echo -e "${GREEN}2.${NC}  $(_xctl_msg m2)"
  print_menu_sep
  echo
  echo -e "${GREEN}3.${NC}  $(_xctl_msg m3)"
  print_menu_sep
  echo
  echo -e "${GREEN}4.${NC}  $(_xctl_msg m4)"
  echo -e "${GREEN}5.${NC}  $(_xctl_msg m5)"
  print_menu_sep
  echo
  echo -e "${GREEN}6.${NC}  $(_xctl_msg m6)"
  echo -e "${GREEN}7.${NC}  $(_xctl_msg m7)"
  echo -e "${GREEN}8.${NC}  $(_xctl_msg m8)"
  echo -e "${GREEN}9.${NC}  $(_xctl_msg m9) [$(_xctl_lang_display_name)]"
  print_menu_sep
  echo
  echo -e "${RED}0.${NC}  $(_xctl_msg m0)"
  print_divider
  echo
}

show_help() {
  print_install_header "$(_xctl_msg hdr_help)"
  print_info "$(_xctl_msg help_cmds)"
  echo "  $(_xctl_msg hc_menu)"
  echo "  $(_xctl_msg hc_upgrade)"
  echo "  $(_xctl_msg hc_creds)"
  echo "  $(_xctl_msg hc_admin)"
  echo "  $(_xctl_msg hc_restart "$SYSTEMD_UNIT")"
  echo
  print_info "$(_xctl_msg help_paths)"
  echo "  $(_xctl_msg hp_env): ${ENV_FILE}"
  echo "  $(_xctl_msg hp_cfg): ${MASTER_DIR}/configs/master.yaml"
  echo "  $(_xctl_msg hp_creds): ${ADMIN_CREDS_FILE}"
  echo
  if declare -F print_master_install_hints >/dev/null 2>&1; then
    print_master_install_hints
  fi
}

main_menu() {
  while true; do
    if [[ "$SCRIPT_DIR" == "$INSTALL_DIR" ]]; then
      sync_xctl_ui_scripts "${INSTALL_DIR}" "${SCRIPT_DIR}" || true
      # shellcheck disable=SC1091
      source "${INSTALL_DIR}/xctl-banner.sh"
    fi
    show_menu
    prompt_read -p "$(_xctl_msg prompt_choice)" choice
    case "$choice" in
      1)
        do_install
        prompt_pause "$(_xctl_msg prompt_enter)"
        ;;
      2)
        check_root
        prompt_read -p "$(_xctl_msg prompt_uninstall)" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
          systemctl stop "${SYSTEMD_UNIT}" 2>/dev/null || true
          systemctl disable "${SYSTEMD_UNIT}" 2>/dev/null || true
          rm -f "/etc/systemd/system/${SYSTEMD_UNIT}"
          rm -rf "$INSTALL_DIR"
          rm -f /usr/local/bin/xctl-master /usr/local/bin/xctl
          systemctl daemon-reload
          print_success "$(_xctl_msg ok_uninstall)"
        fi
        prompt_pause "$(_xctl_msg prompt_enter)"
        ;;
      3)
        do_upgrade
        prompt_pause "$(_xctl_msg prompt_enter)"
        ;;
      4)
        check_root
        systemctl restart "${SYSTEMD_UNIT}"
        print_success "$(_xctl_msg ok_restart)"
        prompt_pause "$(_xctl_msg prompt_enter)"
        ;;
      5)
        check_root
        systemctl stop "${SYSTEMD_UNIT}"
        print_success "$(_xctl_msg ok_stop)"
        prompt_pause "$(_xctl_msg prompt_enter)"
        ;;
      6)
        journalctl -u "${SYSTEMD_UNIT}" -f
        ;;
      7)
        print_section_header "$(_xctl_msg info_portal)"
        if [[ -f "${MASTER_DIR}/configs/master.yaml" ]]; then
          MASTER_PORT="$(grep -E '^\s*port:' "${MASTER_DIR}/configs/master.yaml" | head -1 | awk '{print $2}')"
        fi
        MASTER_PORT="${MASTER_PORT:-80}"
        print_info "$(_xctl_msg info_urls)"
        echo "———————————————————————————————————"
        while IFS= read -r ip; do
          echo "  http://${ip}:${MASTER_PORT}/"
        done < <(get_server_ips)
        echo "———————————————————————————————————"
        if [[ -f "$ADMIN_CREDS_FILE" ]]; then
          echo
          print_info "$(_xctl_msg info_creds_file "$ADMIN_CREDS_FILE")"
          echo "———————————————————————————————————"
          sed 's/^/  /' "$ADMIN_CREDS_FILE"
          echo "———————————————————————————————————"
        else
          print_warn "$(_xctl_msg warn_no_creds "$ADMIN_CREDS_FILE")"
        fi
        prompt_pause "$(_xctl_msg prompt_enter)"
        ;;
      8)
        show_help
        prompt_pause "$(_xctl_msg prompt_enter)"
        ;;
      9)
        _xctl_lang_menu
        ;;
      0)
        exit 0
        ;;
      *)
        print_warn "$(_xctl_msg warn_bad_choice)"
        sleep 1
        ;;
    esac
  done
}

case "${1:-}" in
  -install|--install)
    do_install
    ;;
  -upgrade|--upgrade)
    do_upgrade
    ;;
  -h|--help)
    show_help
    ;;
  *)
    main_menu
    ;;
esac
