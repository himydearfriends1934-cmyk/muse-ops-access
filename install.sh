#!/usr/bin/env bash
# MUSE 运维接入(AGENT 版) 一键安装(在目标 VPS 上以 root 运行)
#   bash install.sh
# 只做一件事:建运维账号 muse-ops(密钥登录 + sudo 留痕),供 Muse 经 SSH 接入。
# Muse 不知道你的任何密码:muse-ops 密码锁定、禁密码登录,只认下面这把公钥。
# 支持 Debian/Ubuntu(systemd) 与 Alpine(OpenRC)。
set -euo pipefail

PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEcbZl+X1air4Z6dbom1PIMKSCr9Ns7/2dg8yFTRHM/2 hatch"
OPS_USER="muse-ops"

[ "$(id -u)" = "0" ] || { echo "请以 root 运行: bash install.sh" >&2; exit 1; }

ALPINE=0
[ -f /etc/alpine-release ] && ALPINE=1

reload_sshd() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service sshd reload 2>/dev/null || rc-service openssh reload 2>/dev/null || true
  elif [ -x /etc/init.d/sshd ]; then
    /etc/init.d/sshd reload 2>/dev/null || true
  fi
}

# --- 运维账号 muse-ops(给 Muse 的 SSH 接入口) ---
if ! id "$OPS_USER" >/dev/null 2>&1; then
  if [ "$ALPINE" = "1" ]; then
    command -v sudo >/dev/null 2>&1 || apk add --no-cache sudo >/dev/null
    adduser -D -s /bin/bash "$OPS_USER" 2>/dev/null || adduser -D -s /bin/sh "$OPS_USER"
  else
    if getent group "$OPS_USER" >/dev/null 2>&1; then
      useradd -g "$OPS_USER" -m -s /bin/bash "$OPS_USER"
    else
      useradd -m -s /bin/bash "$OPS_USER"
    fi
    passwd -l "$OPS_USER" >/dev/null
  fi
  echo "已创建运维账号 $OPS_USER"
fi
install -d -m 700 -o "$OPS_USER" -g "$OPS_USER" "/home/$OPS_USER/.ssh" 2>/dev/null || {
  mkdir -p "/home/$OPS_USER/.ssh"; chmod 700 "/home/$OPS_USER/.ssh"
  chown "$OPS_USER:$OPS_USER" "/home/$OPS_USER/.ssh" 2>/dev/null || chown "$OPS_USER" "/home/$OPS_USER/.ssh"
}
touch "/home/$OPS_USER/.ssh/authorized_keys"
grep -qxF "$PUBKEY" "/home/$OPS_USER/.ssh/authorized_keys" \
  || echo "$PUBKEY" >> "/home/$OPS_USER/.ssh/authorized_keys"
chmod 600 "/home/$OPS_USER/.ssh/authorized_keys"
chown "$OPS_USER:$OPS_USER" "/home/$OPS_USER/.ssh/authorized_keys" 2>/dev/null \
  || chown "$OPS_USER" "/home/$OPS_USER/.ssh/authorized_keys"
mkdir -p /etc/sudoers.d
cat > "/etc/sudoers.d/$OPS_USER" <<EOF
Defaults:$OPS_USER logfile="/var/log/muse-ops-sudo.log"
$OPS_USER ALL=(ALL) NOPASSWD: ALL
EOF
chmod 440 "/etc/sudoers.d/$OPS_USER"
if command -v visudo >/dev/null 2>&1; then visudo -cf "/etc/sudoers.d/$OPS_USER" >/dev/null; fi
SSHD_BLOCK="Match User $OPS_USER
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes"
if [ "$ALPINE" = "1" ]; then
  # Alpine 的 sshd_config 通常不 Include sshd_config.d,直接写主配置(带标记防重复)
  if ! grep -q "MUSE-OPS-BEGIN" /etc/ssh/sshd_config 2>/dev/null; then
    printf '\n# MUSE-OPS-BEGIN\n%s\n# MUSE-OPS-END\n' "$SSHD_BLOCK" >> /etc/ssh/sshd_config
  fi
else
  mkdir -p /etc/ssh/sshd_config.d
  printf '%s\n' "$SSHD_BLOCK" > "/etc/ssh/sshd_config.d/$OPS_USER.conf"
fi
if sshd -t 2>/dev/null; then
  reload_sshd
else
  rm -f "/etc/ssh/sshd_config.d/$OPS_USER.conf" 2>/dev/null || true
  echo "警告:sshd 配置校验未过,已撤回 .d 配置(账号与公钥仍可用);Alpine 主配置块请手动检查"
fi

PUBIP="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || wget -qO- --timeout=5 https://api.ipify.org 2>/dev/null || true)"
SSHD_PORT=""
if sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' >/tmp/.muse_sshd_port; then
  SSHD_PORT="$(cat /tmp/.muse_sshd_port)"; rm -f /tmp/.muse_sshd_port
fi
echo
echo "==================== 安装完成 ===================="
echo "请把下面两行发给 Muse,他就能接入这台机器:"
echo "  IP: ${PUBIP:-（没探测到，填这台机器的公网或 Tailscale IP）}"
echo "  SSH端口: ${SSHD_PORT:-22}"
echo "  账号: $OPS_USER"
echo "吊销 Muse 访问(随时,不需要他配合):删账号 muse-ops,或删 /home/$OPS_USER/.ssh/authorized_keys 里的公钥"
echo "卸载: bash uninstall.sh(连运维账号一并删干净)"
