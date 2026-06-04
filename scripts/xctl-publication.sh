#!/usr/bin/env bash
# xctl-publication.sh — 发布仓公共变量（Gitea 脚本优先 / GitHub Releases）
#
# 脚本同步仓：gitea-catxtom-overbook/xctl-publication（Push Mirror → GitHub）
# Releases（master-latest / client-latest）仍在 GitHub。

: "${XCTL_PUBLICATION_REPO:=catxtom/xctl-publication}"
: "${GITHUB_REPO:=${XCTL_PUBLICATION_REPO}}"

: "${XCTL_GITEA_BASE:=http://10.0.1.10:8418}"
: "${XCTL_PUBLICATION_GITEA_OWNER:=gitea-catxtom-overbook}"
: "${XCTL_PUBLICATION_GITEA_REPO:=xctl-publication}"
: "${XCTL_PUBLICATION_GITEA_GIT:=${XCTL_GITEA_BASE}/${XCTL_PUBLICATION_GITEA_OWNER}/${XCTL_PUBLICATION_GITEA_REPO}.git}"
: "${XCTL_PUBLICATION_PROBE_TIMEOUT:=5}"

MASTER_ROLLING_TAG="${MASTER_ROLLING_TAG:-master-latest}"
CLIENT_ROLLING_TAG="${CLIENT_ROLLING_TAG:-client-latest}"

: "${XCTL_SCRIPTS_REF:=main}"

# 探测 Gitea raw 是否可读；不可达则用 GitHub raw
publication_scripts_raw_base() {
  if [[ -n "${XCTL_SCRIPTS_RAW_BASE:-}" ]]; then
    echo "${XCTL_SCRIPTS_RAW_BASE%/}"
    return 0
  fi
  local gitea_raw gh_raw
  gitea_raw="${XCTL_GITEA_BASE%/}/${XCTL_PUBLICATION_GITEA_OWNER}/${XCTL_PUBLICATION_GITEA_REPO}/raw/${XCTL_SCRIPTS_REF}/scripts"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL --connect-timeout "${XCTL_PUBLICATION_PROBE_TIMEOUT}" \
      "${gitea_raw}/install.sh" -o /dev/null 2>/dev/null; then
      echo "$gitea_raw"
      return 0
    fi
  fi
  gh_raw="https://raw.githubusercontent.com/${GITHUB_REPO}/${XCTL_SCRIPTS_REF}/scripts"
  echo "$gh_raw"
}

publication_scripts_source_label() {
  local base
  base="$(publication_scripts_raw_base)"
  case "$base" in
    *"${XCTL_GITEA_BASE}"*) echo "Gitea (${XCTL_PUBLICATION_GITEA_OWNER}/${XCTL_PUBLICATION_GITEA_REPO})" ;;
    *) echo "GitHub (${GITHUB_REPO})" ;;
  esac
}

# Gitea git 是否可访问（发版 push 用）
publication_gitea_git_reachable() {
  command -v git >/dev/null 2>&1 || return 1
  git ls-remote --heads "${XCTL_PUBLICATION_GITEA_GIT}" "${XCTL_SCRIPTS_REF}" >/dev/null 2>&1 \
    || git ls-remote --heads "${XCTL_PUBLICATION_GITEA_GIT}" HEAD >/dev/null 2>&1
}

gh_release_download_url() {
  local tag=$1
  local asset=$2
  echo "https://github.com/${GITHUB_REPO}/releases/download/${tag}/${asset}"
}

master_package_url() {
  local arch=$1
  local tag=${2:-$MASTER_ROLLING_TAG}
  gh_release_download_url "$tag" "xctlmaster-linux-${arch}-latest.tar.gz"
}

client_binary_url() {
  local arch=$1
  local tag=${2:-$CLIENT_ROLLING_TAG}
  gh_release_download_url "$tag" "xctl-client-linux-${arch}"
}

client_sha256_url() {
  local arch=$1
  local tag=${2:-$CLIENT_ROLLING_TAG}
  gh_release_download_url "$tag" "xctl-client-linux-${arch}.sha256"
}

master_install_script_url() {
  echo "$(publication_scripts_raw_base)/install.sh"
}

master_install_curl_pipe() {
  echo "curl -fsSL $(master_install_script_url) | sudo bash -s -- -install"
}

master_install_curl_file() {
  echo "curl -fsSL $(master_install_script_url) -o /tmp/xctl-install.sh && sudo bash /tmp/xctl-install.sh -install"
}

master_install_curl_menu() {
  echo "curl -fsSL $(master_install_script_url) | sudo bash"
}

master_install_bash_process() {
  echo "bash <(curl -fsSL $(master_install_script_url))"
}

# 兼容旧名
master_install_curl_hint() { master_install_curl_pipe; }
master_install_curl_file_hint() { master_install_curl_file; }

# 发版完成 / 安装结束：多种安装入口说明
print_master_install_hints() {
  local src url
  src="$(publication_scripts_source_label)"
  url="$(master_install_script_url)"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  XCTL Master 远程安装（脚本源: ${src}）"
  echo "  ${url}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  [直接安装]  非交互全新安装（推荐，需 root）"
  echo "    $(master_install_curl_pipe)"
  echo ""
  echo "  [下载安装]  sudo 下更稳（先落盘再执行）"
  echo "    $(master_install_curl_file)"
  echo ""
  echo "  [菜单模式]  安装 / 升级 / 凭据 / 卸载（交互）"
  echo "    $(master_install_curl_menu)"
  echo ""
  echo "  [进程替换]  仅当前用户 bash，勿与 sudo 同用"
  echo "    $(master_install_bash_process)"
  echo ""
  echo "  装好后: sudo xctl master | sudo xctl master creds"
  echo "  二进制 Release 仍在 GitHub: ${GITHUB_REPO} (master-latest)"
  echo ""
}

# 已安装环境：从当前可达的 raw 源同步 UI 脚本
sync_xctl_ui_scripts() {
  local install_dir="${1:-/etc/xctl}"
  local script_dir="${2:-$install_dir}"
  local raw_base f dest tmp

  [[ "$script_dir" == "$install_dir" ]] || return 0
  [[ -d "$install_dir" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0

  raw_base="$(publication_scripts_raw_base)"

  for f in xctl-banner.sh xctl-messages.sh xctl-messages.en.sh xctl-master-install.sh xctl-publication.sh xctl; do
    dest="${install_dir}/${f}"
    tmp="$(mktemp)"
    if ! curl -fsSL --connect-timeout "${XCTL_PUBLICATION_PROBE_TIMEOUT}" \
      "${raw_base}/${f}" -o "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      continue
    fi
    if [[ ! -f "$dest" ]] || ! cmp -s "$tmp" "$dest"; then
      cp "$tmp" "$dest"
      case "$f" in
        xctl)
          cp "$tmp" /usr/local/bin/xctl 2>/dev/null || true
          chmod +x /usr/local/bin/xctl 2>/dev/null || true
          ;;
        xctl-master-install.sh)
          chmod +x "$dest"
          ;;
      esac
    fi
    rm -f "$tmp"
  done
}

# GitHub Release 要求默认分支至少有一个 commit（空仓库会 422 Repository is empty）
gh_publication_repo_preflight() {
  command -v gh >/dev/null || {
    echo "需要 GitHub CLI: https://cli.github.com/" >&2
    exit 1
  }

  local is_empty
  if ! is_empty="$(gh repo view "$GITHUB_REPO" --json isEmpty -q .isEmpty 2>&1)"; then
    echo "ERROR: 无法访问 GitHub 仓库 ${GITHUB_REPO}" >&2
    echo "$is_empty" >&2
    echo "请确认仓库已创建且 gh auth login 有权限。" >&2
    exit 1
  fi

  if [[ "$is_empty" == "true" ]]; then
    cat >&2 <<EOF
ERROR: ${GITHUB_REPO} 仍是空仓库，无法创建 Release（HTTP 422 Repository is empty）。

请先在默认分支 push 至少一个 commit，例如：

  mkdir -p /tmp/xctl-publication && cd /tmp/xctl-publication
  git init
  echo "# xctl-publication" > README.md
  git add README.md
  git commit -m "chore: initialize publication repo"
  git branch -M main
  git remote add origin https://github.com/${GITHUB_REPO}.git
  git push -u origin main

或先在 Gitea 创建 ${XCTL_PUBLICATION_GITEA_GIT} 并 push，再配置 Push Mirror → GitHub。

完成后重新执行发版命令。
EOF
    exit 1
  fi
}

gh_release_upload_assets() {
  local tag=$1
  shift
  local assets=("$@")
  local total=${#assets[@]}
  local i=0
  local f size

  for f in "${assets[@]}"; do
    i=$((i + 1))
    size="$(du -h "$f" | awk '{print $1}')"
    echo "    [${i}/${total}] 上传 $(basename "$f") (${size})…"
    gh release upload "$tag" "$f" --repo "$GITHUB_REPO" --clobber
  done
}

gh_release_upload_rolling() {
  local rolling_tag=$1
  local title=$2
  shift 2
  local assets=("$@")

  if gh release view "$rolling_tag" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    echo "==> 更新 rolling release ${rolling_tag}"
  else
    echo "==> 创建 rolling release ${rolling_tag}（随后上传 ${#assets[@]} 个文件，请稍候）"
    gh release create "$rolling_tag" \
      --repo "$GITHUB_REPO" \
      --title "$title" \
      --notes "Rolling 渠道；装机脚本默认拉取此 tag 下资源。"
  fi
  gh_release_upload_assets "$rolling_tag" "${assets[@]}"
}

gh_release_upload_versioned() {
  local tag=$1
  local title=$2
  local notes=$3
  shift 3
  local assets=("$@")

  if gh release view "$tag" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    echo "WARN: release ${tag} 已存在，跳过版本 tag（仅更新 rolling）" >&2
    return 0
  fi
  echo "==> 创建版本 release ${tag}（上传 ${#assets[@]} 个文件，约 $(du -ch "${assets[@]}" | awk '/total$/ {print $1}')）"
  gh release create "$tag" \
    --repo "$GITHUB_REPO" \
    --title "$title" \
    --notes "$notes"
  gh_release_upload_assets "$tag" "${assets[@]}"
}
