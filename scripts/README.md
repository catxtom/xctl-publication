# xctl-publication — XCTL 安装脚本发布仓

> 由 xuictl 源码 `./scripts/publish-github.sh scripts` 同步（Gitea git 优先），请勿手改 `scripts/`。  
> 发版说明：[docs/how-to/xctl-publication-publish.md](../../docs/how-to/xctl-publication-publish.md)

## 仓库

| 远程 | 地址 |
| --- | --- |
| **Gitea（脚本 push 优先）** | `http://10.0.1.10:8418/gitea-catxtom-overbook/xctl-publication` |
| **GitHub（Release + Mirror 备份）** | `https://github.com/catxtom/xctl-publication` |

二进制 Release（`master-latest` / `client-latest`）：发版时 **先 Gitea Releases，再 GitHub**；装机时 URL **自动探测 Gitea**，否则 GitHub。

---

## 远程安装 Master（多种方式）

脚本入口：`scripts/install.sh`（Gitea raw 或 GitHub raw，由运行环境自动探测）。

### [直接安装] 非交互全新安装（推荐，需 root）

```bash
curl -fsSL https://raw.githubusercontent.com/catxtom/xctl-publication/main/scripts/install.sh | sudo bash -s -- -install
```

（内网可达 Gitea 时，实际 URL 为  
`http://10.0.1.10:8418/gitea-catxtom-overbook/xctl-publication/raw/main/scripts/install.sh`）

### [下载安装] sudo 环境更稳

```bash
curl -fsSL …/scripts/install.sh -o /tmp/xctl-install.sh
sudo bash /tmp/xctl-install.sh -install
```

### [菜单模式] 安装 / 升级 / 凭据 / 卸载

```bash
curl -fsSL …/scripts/install.sh | sudo bash
```

### [进程替换] 仅当前用户（勿 `sudo bash <(curl …)`）

```bash
bash <(curl -fsSL …/scripts/install.sh)
```

装好后：

```bash
sudo xctl master          # 运维菜单
sudo xctl master creds    # 管理入口 + 管理员凭据
```

---

## scripts/ 目录

| 文件 | 说明 |
| --- | --- |
| `install.sh` | curl 入口 |
| `xctl-master-install.sh` | 安装 / 菜单 / 升级 |
| `xctl` | `/usr/local/bin/xctl` |
| `xctl-banner.sh` | 终端 UI |
| `xctl-publication.sh` | URL 构造（Gitea 优先探测） |

## 二进制

- `master-latest` → `xctlmaster-linux-{amd64,arm64}-latest.tar.gz`
- `client-latest` → `xctl-client-linux-{amd64,arm64}`
