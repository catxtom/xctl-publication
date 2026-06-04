#!/usr/bin/env bash
# xctl-publication.sh — 发布仓公共变量（Gitea 脚本优先 / GitHub Releases）

_xctl_pub_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
if [[ -n "$_xctl_pub_root" && -f "${_xctl_pub_root}/.env.local" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${_xctl_pub_root}/.env.local"
  set +a
fi
unset _xctl_pub_root
#
# Release 发版：默认本机直传 GitHub（公网用户下载）
# Gitea Release 可选（XCTL_PUBLICATION_ALSO_GITEA=1）；scripts 仍可 git push Gitea + Mirror
# 装机探测：能访问 Gitea 则用 Gitea URL，否则 GitHub

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

gitea_release_download_url() {
  local tag=$1
  local asset=$2
  echo "${XCTL_GITEA_BASE%/}/${XCTL_PUBLICATION_GITEA_OWNER}/${XCTL_PUBLICATION_GITEA_REPO}/releases/download/${tag}/${asset}"
}

publication_release_asset_reachable() {
  local url=$1
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsSL --connect-timeout "${XCTL_PUBLICATION_PROBE_TIMEOUT}" -r 0-0 -o /dev/null "$url" 2>/dev/null
}

publication_release_download_url() {
  local tag=$1
  local asset=$2
  local gitea_url
  gitea_url="$(gitea_release_download_url "$tag" "$asset")"
  if publication_release_asset_reachable "$gitea_url"; then
    echo "$gitea_url"
    return 0
  fi
  gh_release_download_url "$tag" "$asset"
}

master_package_url() {
  local arch=$1
  local tag=${2:-$MASTER_ROLLING_TAG}
  publication_release_download_url "$tag" "xctlmaster-linux-${arch}-latest.tar.gz"
}

client_binary_url() {
  local arch=$1
  local tag=${2:-$CLIENT_ROLLING_TAG}
  publication_release_download_url "$tag" "xctl-client-linux-${arch}"
}

client_sha256_url() {
  local arch=$1
  local tag=${2:-$CLIENT_ROLLING_TAG}
  publication_release_download_url "$tag" "xctl-client-linux-${arch}.sha256"
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
  echo "  公网用户: 仅 GitHub Releases（${GITHUB_REPO}，master-latest / client-latest）"
  echo "  内网: 脚本/二进制探测 Gitea，不可达时同上 GitHub"
  echo ""
}

publication_print_github_release_urls() {
  local tag=$1
  echo ""
  echo "==> 公网下载（GitHub Release）"
  echo "    https://github.com/${GITHUB_REPO}/releases/tag/${tag}"
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

publication_gitea_api_base() {
  echo "${XCTL_GITEA_BASE}/api/v1/repos/${XCTL_PUBLICATION_GITEA_OWNER}/${XCTL_PUBLICATION_GITEA_REPO}"
}

publication_gitea_token() {
  if [[ -n "${XCTL_GITEA_TOKEN:-}" ]]; then
    echo "$XCTL_GITEA_TOKEN"
    return 0
  fi
  return 1
}

publication_gitea_api_enabled() {
  publication_gitea_token >/dev/null 2>&1 && publication_gitea_git_reachable
}

# --- Gitea Releases（API 上传；Push Mirror 不同步附件）---

gitea_release_id_by_tag() {
  local tag=$1
  local api token body
  api="$(publication_gitea_api_base)"
  token="$(publication_gitea_token)" || return 1
  body="$(curl -fsSL -H "Authorization: token ${token}" "${api}/releases/tags/${tag}" 2>/dev/null)" || return 1
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id") or "")' <<<"$body" 2>/dev/null
}

gitea_release_ensure() {
  local tag=$1 title=$2 body=$3
  local api token id payload
  api="$(publication_gitea_api_base)"
  token="$(publication_gitea_token)" || return 1
  id="$(gitea_release_id_by_tag "$tag" 2>/dev/null || true)"
  if [[ -n "$id" ]]; then
    echo "$id"
    return 0
  fi
  payload="$(python3 -c 'import json,sys; print(json.dumps({
    "tag_name": sys.argv[1],
    "name": sys.argv[2],
    "body": sys.argv[3],
    "target_commitish": sys.argv[4],
  }))' "$tag" "$title" "$body" "${XCTL_SCRIPTS_REF}")"
  body="$(curl -fsSL -X POST -H "Authorization: token ${token}" -H "Content-Type: application/json" \
    -d "$payload" "${api}/releases" 2>/dev/null)" || return 1
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id") or "")' <<<"$body"
}

gitea_release_clear_assets() {
  local release_id=$1
  local api token rel_body asset_id
  api="$(publication_gitea_api_base)"
  token="$(publication_gitea_token)" || return 1
  rel_body="$(curl -fsSL -H "Authorization: token ${token}" "${api}/releases/${release_id}" 2>/dev/null)" || return 1
  while IFS= read -r asset_id; do
    [[ -n "$asset_id" ]] || continue
    curl -fsSL -X DELETE -H "Authorization: token ${token}" \
      "${api}/releases/${release_id}/assets/${asset_id}" >/dev/null 2>&1 || true
  done < <(python3 -c 'import json,sys; d=json.load(sys.stdin);
for a in d.get("assets") or []:
  if a.get("id"): print(a["id"])' <<<"$rel_body")
}

gitea_release_upload_assets() {
  local release_id=$1
  shift
  local api token f name total i size
  api="$(publication_gitea_api_base)"
  token="$(publication_gitea_token)" || return 1
  total=$#
  i=0
  for f in "$@"; do
    i=$((i + 1))
    name="$(basename "$f")"
    size="$(du -h "$f" | awk '{print $1}')"
    echo "    [Gitea ${i}/${total}] 上传 ${name} (${size})…"
    curl -fsSL -X POST -H "Authorization: token ${token}" \
      "${api}/releases/${release_id}/assets?name=${name}" \
      -F "attachment=@${f}" >/dev/null
  done
}

gitea_release_upload_rolling() {
  local rolling_tag=$1 title=$2
  shift 2
  local release_id

  publication_gitea_api_enabled || return 1
  echo "==> Gitea rolling release ${rolling_tag}"
  release_id="$(gitea_release_ensure "$rolling_tag" "$title" "Rolling 渠道；装机默认拉取此 tag。")" || return 1
  gitea_release_clear_assets "$release_id" || true
  gitea_release_upload_assets "$release_id" "$@"
}

gitea_release_upload_versioned() {
  local tag=$1 title=$2 notes=$3
  shift 3
  local release_id

  publication_gitea_api_enabled || return 1
  if gitea_release_id_by_tag "$tag" >/dev/null 2>&1; then
    echo "WARN: Gitea release ${tag} 已存在，跳过版本 tag" >&2
    return 0
  fi
  echo "==> Gitea 版本 release ${tag}"
  release_id="$(gitea_release_ensure "$tag" "$title" "$notes")" || return 1
  gitea_release_upload_assets "$release_id" "$@"
}

# 将 Gitea 某 tag 的 Release 附件同步到 GitHub（从 Gitea 下载再 gh upload，非本机双份构建）
gitea_release_sync_tag_to_github() {
  local tag=$1
  local api token rel_json name url tmp total i

  publication_gitea_api_enabled || return 1
  api="$(publication_gitea_api_base)"
  token="$(publication_gitea_token)" || return 1

  echo "==> Gitea → GitHub 同步 Release: ${tag}"
  rel_json="$(curl -fsSL -H "Authorization: token ${token}" "${api}/releases/tags/${tag}" 2>/dev/null)" || {
    echo "WARN: Gitea 无 release ${tag}" >&2
    return 1
  }

  gh_publication_repo_preflight
  if ! gh release view "$tag" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    local title body
    title="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("name") or sys.argv[1])' <<<"$rel_json" "$tag" 2>/dev/null || echo "$tag")"
    body="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("body") or "")' <<<"$rel_json" 2>/dev/null || true)"
    gh release create "$tag" --repo "$GITHUB_REPO" --title "$title" --notes "${body:-Synced from Gitea}"
  fi

  _asset_lines=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && _asset_lines+=("$line")
  done < <(python3 -c 'import json,sys
d=json.load(sys.stdin)
base=sys.argv[1]
owner=sys.argv[2]
repo=sys.argv[3]
tag=sys.argv[4]
for a in d.get("assets") or []:
  n=a.get("name") or ""
  u=a.get("browser_download_url") or ""
  if not u and n:
    u=f"{base}/{owner}/{repo}/releases/download/{tag}/{n}"
  if n and u:
    print(n+"\t"+u)' <<<"$rel_json" "${XCTL_GITEA_BASE%/}" "${XCTL_PUBLICATION_GITEA_OWNER}" \
    "${XCTL_PUBLICATION_GITEA_REPO}" "$tag")

  total=${#_asset_lines[@]}
  if [[ "$total" -eq 0 ]]; then
    echo "WARN: ${tag} 无附件可同步" >&2
    return 1
  fi

  i=0
  for line in "${_asset_lines[@]}"; do
    name="${line%%$'\t'*}"
    url="${line#*$'\t'}"
    i=$((i + 1))
    tmp="$(mktemp)"
    echo "    [GitHub ${i}/${total}] ${name} ← Gitea"
    curl -fsSL --connect-timeout 15 --max-time 600 \
      -H "Authorization: token ${token}" "$url" -o "$tmp"
    gh release upload "$tag" "$tmp" --repo "$GITHUB_REPO" --clobber
    rm -f "$tmp"
  done
  echo "==> GitHub ${tag} 已与 Gitea 附件对齐"
}

# Release 发版：本机构建物直传 GitHub；Gitea 仅当 XCTL_PUBLICATION_ALSO_GITEA=1
publication_release_upload_rolling() {
  local rolling_tag=$1 title=$2
  shift 2
  local also_gitea="${XCTL_PUBLICATION_ALSO_GITEA:-0}"

  gh_publication_repo_preflight
  echo "==> GitHub rolling release ${rolling_tag}"
  gh_release_upload_rolling "$rolling_tag" "$title" "$@"
  publication_print_github_release_urls "$rolling_tag"

  if [[ "$also_gitea" == "1" ]]; then
    if gitea_release_upload_rolling "$rolling_tag" "$title" "$@"; then
      echo "==> 已额外上传 Gitea ${rolling_tag}"
    else
      echo "WARN: Gitea Release 跳过（内网不可达或未配置 XCTL_GITEA_TOKEN）" >&2
    fi
  fi
}

publication_release_upload_versioned() {
  local tag=$1 title=$2 notes=$3
  shift 3
  local also_gitea="${XCTL_PUBLICATION_ALSO_GITEA:-0}"

  gh_publication_repo_preflight
  echo "==> GitHub 版本 release ${tag}"
  gh_release_upload_versioned "$tag" "$title" "$notes" "$@"
  publication_print_github_release_urls "$tag"

  if [[ "$also_gitea" == "1" ]]; then
    gitea_release_upload_versioned "$tag" "$title" "$notes" "$@" || \
      echo "WARN: Gitea 版本 release ${tag} 跳过" >&2
  fi
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
