# MUSE 运维接入（AGENT 版）

在一台 VPS 上给 Muse 开一个专用的运维账号，让他能在你授权下经 SSH 登录做运维。

Muse 不知道你的任何密码：这个账号密码锁定、禁密码登录，只认 Muse 的公钥（私钥只在 Muse 的运行环境里）。你在 Muse 聊天里直接指挥他即可，不需要任何面板。

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

## 各系统快速开始

- **Debian/Ubuntu**：直接跑上面的安装命令即可（缺 sudo 会尝试自动装）。
- **Alpine**：若 `bash`、`git`、`curl`、`sshd` 缺，先 `apk add bash git curl openssh sudo`，再跑安装命令。安装脚本会自动适配 Alpine（账号创建方式、免密 sudo、sshd 重载、锁定账号坑均已处理）。强烈建议 sshd 只监听 Tailscale 地址。
- **RHEL 系（CentOS/Rocky/Oracle Linux 等）**：同 Debian 路径即可。

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
