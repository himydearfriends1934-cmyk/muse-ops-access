# MUSE 运维接入（AGENT 版）

在一台 VPS 上给 Muse 开一个专用的运维账号，让他能在你授权下经 SSH 登录做运维。

Muse 不知道你的任何密码：这个账号密码锁定、禁密码登录，只认 Muse 的公钥（私钥只在 Muse 的运行环境里）。你在 Muse 聊天里直接指挥他即可，不需要任何面板。

## 一行安装（curl，服务器上 root 执行，不用先下载仓库）

```
curl -fsSL https://raw.githubusercontent.com/himydearfriends1934-cmyk/muse-ops-access/main/install.sh | bash
```

连 bash 都没有的精简机器改用引导脚本（自动补齐依赖，同目录缺 install.sh 时会自己去仓库拉取）：

```
curl -fsSL https://raw.githubusercontent.com/himydearfriends1934-cmyk/muse-ops-access/main/boot.sh | sh
```

注意：仓库托管在 GitHub、只有 IPv4 入口，纯 IPv6 机器拉不到，仍需 Taildrop/scp 把 zip 送过去再本地安装。

## 一键安装 / 卸载（服务器上 root 执行）

```
git clone https://github.com/himydearfriends1934-cmyk/muse-ops-access.git
cd muse-ops-access
bash manage.sh
```

```
========== MUSE 运维接入(AGENT 版) ==========
  1) 安装/更新
  2) 卸载软件及依赖
  0) 退出
```

- **选 1**：建运维账号 `muse-ops` 并写入 Muse 的公钥，配置免密 sudo（所有 sudo 操作记到 `/var/log/muse-ops-sudo.log`），仅对该账号禁密码登录，不影响你自己其他账号。
- **选 2**：彻底卸载，删除 `muse-ops` 账号及其 sudo、sshd 配置；若机器上有旧版面板残留（程序/服务/数据/面板账号），一并清理。

也可以直接带参数：`bash manage.sh install` / `bash manage.sh uninstall` / `bash manage.sh verify`，或跳过菜单直接运行 `bash install.sh` / `bash uninstall.sh` / `bash verify.sh`。

## 各系统快速开始（脚本自动识别机器类型）

安装脚本会自动识别发行版家族（Debian/Ubuntu、RHEL 系、Alpine、Arch、SUSE）、初始化系统（systemd/OpenRC/SysV），并按类型自动适配：缺 `sudo`、`sshd` 时自动补装并启用，账号创建与 sshd 配置写法按系统分别处理。

- **常规机器**：直接跑上面的安装命令即可。
- **连 bash/sshd 都缺的精简机器**（如 Alpine 默认、最小化云镜像）：先把文件弄到机器上，然后跑 `sh boot.sh`——它会先补齐 bash、openssh、sudo、curl，再自动转入正式安装。
- **没有 git 的机器**：不用装 git，下载仓库 zip 解压后跑 `bash manage.sh install`（或 `sh boot.sh`）。
- **纯 IPv6 机器**：github.com 只有 IPv4、没有 IPv6 地址，这类机器**下载不了 zip**，属正常现象。用 Tailscale 传文件（Taildrop）或从另一台机器 scp 把 zip 送过去，解压后照常安装；安装自检会优先打印 Tailscale IP，那就是发给 Muse 的接入地址。
- **Alpine 特别说明**：脚本已处理无 PAM 的 sshd 拒绝 `!` 锁定账号的坑；强烈建议 sshd 只监听 Tailscale 地址。

## 装完这样交付（重要）

安装脚本跑完会自动打印一段**安装自检**（账号、公钥、权限、sudoers、sshd 生效配置、监听端口逐项打勾）。

1. 若有 `[FAIL]`，先别急着喊 Muse 连：把整段自检输出发给他，他直接判断缺哪一项。
2. 全部通过后，把脚本末尾打印的 **IP 与 SSH 端口** 发给 Muse，他接入后再做只读核验。
3. 之后任何时候怀疑连不上，跑 `bash verify.sh`（只读），输出整段发给 Muse 定位。

你经 Tailscale 内网登录更安全：公网 SSH 可以全部关掉，只留 Tailscale 通道。

## 吊销 Muse 的访问（随时，不需要 Muse 配合）

```
userdel -r muse-ops
```

或只删 `/home/muse-ops/.ssh/authorized_keys` 里的公钥。删完他立刻进不来。

## 说明

- 本仓库已精减为 AGENT 版（仅运维账号）。早期的面板版（含对话/审批/审计面板）保留在 Git 标签 `with-panel-final` 中，需要时可 checkout 回来安装。
- Muse 的 sudo 操作全量记日志（`/var/log/muse-ops-sudo.log`），随时可查。
