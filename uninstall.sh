#!/usr/bin/env bash
# MUSE 运维接入(AGENT 版) 一键卸载(以 root 运行)
#   bash uninstall.sh
# 删除运维账号 muse-ops 及其 sudo、sshd 配置;若检测到旧版面板残留,一并清理。
# 删完 Muse 立刻无法再登录这台机器。支持 Debian/Ubuntu 与 Alpine。
set -euo pipefail

OPS_USER="muse-ops"
PANEL_USER="muse-panel"
APP_DIR="/opt/muse-ops-panel"
DATA_DIR="/var/lib/muse-ops-panel"

[ "$(id -u)" = "0" ] || { echo "请以 root 运行: bash uninstall.sh" >&2; exit 1; }

# 发行版家族识别(与 install.sh 同口径,保证各类机器删法一致)
ALPINE=0
if [ -f /etc/os-release ]; then
  _osid="$(grep -E '^ID=' /etc/os-release | head -1 | cut -d= -f2- | tr -d '"')"
  _oslike="$(grep -E '^ID_LIKE=' /etc/os-release | head -1 | cut -d= -f2- | tr -d '"')"
  case " $_osid $_oslike " in *" alpine "*) ALPINE=1 ;; esac
fi
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

del_ops_user() {
  if [ "$ALPINE" = "1" ] || ! command -v userdel >/dev/null 2>&1; then
    deluser --remove-home "$OPS_USER" 2>/dev/null || deluser "$OPS_USER" 2>/dev/null || true
    delgroup "$OPS_USER" 2>/dev/null || true
  else
    userdel -r "$OPS_USER" 2>/dev/null || true
    getent group "$OPS_USER" >/dev/null 2>&1 && groupdel "$OPS_USER" 2>/dev/null || true
  fi
}

# --- 1) 运维账号 muse-ops(本系统的核心,卸载即断 Muse 接入) ---
rm -f "/etc/sudoers.d/$OPS_USER" "/etc/ssh/sshd_config.d/$OPS_USER.conf" /var/log/muse-ops-sudo.log
if [ "$ALPINE" = "1" ] && [ -f /etc/ssh/sshd_config ] && grep -q "MUSE-OPS-BEGIN" /etc/ssh/sshd_config; then
  sed -i '/# MUSE-OPS-BEGIN/,/# MUSE-OPS-END/d' /etc/ssh/sshd_config
fi
if sshd -t 2>/dev/null; then reload_sshd; fi
id "$OPS_USER" >/dev/null 2>&1 && del_ops_user
echo "运维账号 $OPS_USER 已删除,Muse 不再能登录这台机器"

# --- 2) 旧版面板残留(如有,一并清理;没有则自动跳过) ---
if [ -d "$APP_DIR" ] || [ -d "$DATA_DIR" ] || id "$PANEL_USER" >/dev/null 2>&1 \
   || [ -f /etc/systemd/system/muse-ops-panel.service ] || [ -e /usr/local/bin/muse-panel-ctl ]; then
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now muse-ops-panel.service 2>/dev/null || true
    rm -rf /etc/systemd/system/muse-ops-panel.service.d
    systemctl daemon-reload 2>/dev/null || true
  fi
  rm -f /etc/systemd/system/muse-ops-panel.service
  rm -f /usr/local/bin/muse-panel-ctl
  rm -f "/etc/sudoers.d/$PANEL_USER"
  rm -rf "$APP_DIR" "$DATA_DIR"
  if id "$PANEL_USER" >/dev/null 2>&1; then
    if [ "$ALPINE" = "1" ]; then deluser "$PANEL_USER" 2>/dev/null || true
    else userdel "$PANEL_USER" 2>/dev/null || true; fi
  fi
  if [ "$ALPINE" != "1" ]; then
    getent group "$PANEL_USER" >/dev/null 2>&1 && groupdel "$PANEL_USER" 2>/dev/null || true
  fi
  echo "检测到旧版面板残留,已一并清理(程序/服务/数据/面板账号)"
fi

echo "卸载完成"
