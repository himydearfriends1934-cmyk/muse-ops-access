#!/usr/bin/env bash
# MUSE 运维接入(AGENT 版) 一键安装(在目标 VPS 上以 root 运行)
#   bash install.sh
# 只做一件事:建运维账号 muse-ops(密钥登录 + sudo 留痕),供 Muse 经 SSH 接入。
# Muse 不知道你的任何密码:muse-ops 密码锁定、禁密码登录,只认下面这把公钥。
set -euo pipefail

PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEcbZl+X1air4Z6dbom1PIMKSCr9Ns7/2dg8yFTRHM/2 hatch"
OPS_USER="muse-ops"

[ "$(id -u)" = "0" ] || { echo "请以 root 运行: bash install.sh" >&2; exit 1; }

# --- 运维账号 muse-ops(给 Muse 的 SSH 接入口) ---
if ! id "$OPS_USER" >/dev/null 2>&1; then
  if getent group "$OPS_USER" >/dev/null 2>&1; then
    useradd -g "$OPS_USER" -m -s /bin/bash "$OPS_USER"
  else
    useradd -m -s /bin/bash "$OPS_USER"
  fi
  passwd -l "$OPS_USER" >/dev/null
  echo "已创建运维账号 $OPS_USER"
fi
install -d -m 700 -o "$OPS_USER" -g "$OPS_USER" "/home/$OPS_USER/.ssh"
touch "/home/$OPS_USER/.ssh/authorized_keys"
grep -qxF "$PUBKEY" "/home/$OPS_USER/.ssh/authorized_keys" \
  || echo "$PUBKEY" >> "/home/$OPS_USER/.ssh/authorized_keys"
chmod 600 "/home/$OPS_USER/.ssh/authorized_keys"
chown "$OPS_USER:$OPS_USER" "/home/$OPS_USER/.ssh/authorized_keys"
cat > "/etc/sudoers.d/$OPS_USER" <<EOF
Defaults:$OPS_USER logfile="/var/log/muse-ops-sudo.log"
$OPS_USER ALL=(ALL) NOPASSWD: ALL
EOF
chmod 440 "/etc/sudoers.d/$OPS_USER"
visudo -cf "/etc/sudoers.d/$OPS_USER" >/dev/null
mkdir -p /etc/ssh/sshd_config.d
cat > "/etc/ssh/sshd_config.d/$OPS_USER.conf" <<EOF
Match User $OPS_USER
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
EOF
if sshd -t 2>/dev/null; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
else
  rm -f "/etc/ssh/sshd_config.d/$OPS_USER.conf"
  echo "警告:sshd 配置校验未过,已撤回该账号的 sshd 限制(账号与公钥仍可用)"
fi

PUBIP="$(curl -s --max-time 5 https://api.ipify.org || true)"
SSHD_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
echo
echo "==================== 安装完成 ===================="
echo "请把下面两行发给 Muse,他就能接入这台机器:"
echo "  IP: ${PUBIP:-（没探测到，填这台机器的公网或 Tailscale IP）}"
echo "  SSH端口: ${SSHD_PORT:-22}"
echo "  账号: $OPS_USER"
echo "吊销 Muse 访问(随时,不需要他配合):userdel -r $OPS_USER,或删 /home/$OPS_USER/.ssh/authorized_keys 里的公钥"
echo "卸载: bash uninstall.sh(连运维账号一并删干净)"
