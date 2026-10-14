#!/bin/sh
# 为 Muse 开通专用运维账号 muse-ops(密钥登录 + sudo),在 OpenWrt 上以 root 运行
#   sh setup-muse-ops-openwrt.sh
# 幂等:可重复运行,不会重复添加公钥,也不会动其他账号与你自己的登录方式。
# 注意: OpenWrt 使用 dropbear 而非 OpenSSH,procd 而非 systemd,opkg 而非 apt/apk。
set -eu

PUBKEY1="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEcbZl+X1air4Z6dbom1PIMKSCr9Ns7/2dg8yFTRHM/2 hatch"
PUBKEY2="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICSv9AzBPV16GtGk4C5pr9qX/Y+8J7vy7W+UjQMqOa+c himydearfriends1934@gmail.com"
OPS_USER="muse-ops"

[ "$(id -u)" = "0" ] || { echo "请以 root 运行: sh setup-muse-ops-openwrt.sh" >&2; exit 1; }

# 1) 专用账号(无密码,只能密钥登录)
if ! id "$OPS_USER" >/dev/null 2>&1; then
  # OpenWrt 的 useradd 来自 shadow-utils(若已装),否则用 adduser(busybox)
  if command -v useradd >/dev/null 2>&1; then
    useradd -m -s /bin/ash "$OPS_USER"
  else
    adduser -D -s /bin/ash "$OPS_USER"
  fi
  # 锁定密码(只能密钥登录)
  passwd -l "$OPS_USER" >/dev/null 2>&1 || true
  echo "已创建账号 $OPS_USER"
fi

# 2) 安装 Muse 与 Antigravity 的公钥(OpenWrt busybox 无 install 命令,用 mkdir/chmod/chown 代替)
HOME_DIR="$(eval echo ~$OPS_USER)"
mkdir -p "$HOME_DIR/.ssh"
chmod 700 "$HOME_DIR/.ssh"
chown "$OPS_USER:$OPS_USER" "$HOME_DIR/.ssh"
touch "$HOME_DIR/.ssh/authorized_keys"
grep -qxF "$PUBKEY1" "$HOME_DIR/.ssh/authorized_keys" || echo "$PUBKEY1" >> "$HOME_DIR/.ssh/authorized_keys"
grep -qxF "$PUBKEY2" "$HOME_DIR/.ssh/authorized_keys" || echo "$PUBKEY2" >> "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
chown "$OPS_USER:$OPS_USER" "$HOME_DIR/.ssh/authorized_keys"
echo "公钥已安装"

# 3) sudo:尝试安装,装不上则降级提示
SUDO_OK=0
if [ ! -f /etc/sudoers ]; then
  echo "正在尝试安装 sudo(opkg)..."
  opkg update >/dev/null 2>&1 || true
  if opkg install sudo >/dev/null 2>&1; then
    echo "sudo 安装成功"
  else
    echo "警告: sudo 安装失败(可能是闪存不足或无网络),跳过 sudo 配置"
  fi
fi
if [ -f /etc/sudoers ]; then
  mkdir -p /etc/sudoers.d
  cat > "/etc/sudoers.d/$OPS_USER" <<EOF
Defaults:$OPS_USER logfile="/var/log/muse-ops-sudo.log"
$OPS_USER ALL=(ALL) NOPASSWD: ALL
EOF
  chmod 440 "/etc/sudoers.d/$OPS_USER"
  if visudo -cf "/etc/sudoers.d/$OPS_USER" 2>/dev/null; then
    echo "sudo 免密已配置"
    SUDO_OK=1
  else
    rm -f "/etc/sudoers.d/$OPS_USER"
    echo "警告: sudoers 校验未过,已撤回"
  fi
fi

# 4) dropbear:确认公钥认证开启(默认即开,此处仅做检查)
# OpenWrt 的 dropbear 默认允许公钥登录,无需额外配置。
# 如需仅 Tailscale 可达,请在防火墙中限制 22 端口来源。
if [ "$SUDO_OK" = "0" ]; then
  echo
  echo "注意: 本机无 sudo,muse-ops 账号权限受限。"
  echo "如需完整运维能力,可手动 opkg install sudo 后重跑本脚本,"
  echo "或直接将公钥加入 root 账号(安全性较低,不推荐):"
  echo "  mkdir -p /root/.ssh && echo '$PUBKEY' >> /root/.ssh/authorized_keys"
fi

# 5) 输出接入信息
PUBIP="$(wget -qO- --timeout=5 https://api.ipify.org 2>/dev/null || curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)"
echo
echo "完成。请把下面几行原样发回给 Muse:"
echo "  Tailscale IP: (填这台的 Tailscale 地址,优先用这个)"
echo "  公网 IPv4: ${PUBIP:-(没探测到,填公网 IP)}"
echo "  SSH端口: 22"
echo "  账号: $OPS_USER"
echo "  系统: OpenWrt$(cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_RELEASE | cut -d"'" -f2 | sed 's/^/ /')"
echo "吊销方法: userdel -r $OPS_USER(或只删 $HOME_DIR/.ssh/authorized_keys 里的公钥)"
