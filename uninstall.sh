#!/usr/bin/env bash
# MUSE 运维接入(AGENT 版) 一键卸载(以 root 运行)
#   bash uninstall.sh
# 删除运维账号 muse-ops 及其 sudo、sshd 配置;若检测到旧版面板残留,一并清理。
# 删完 Muse 立刻无法再登录这台机器。
set -euo pipefail

OPS_USER="muse-ops"
PANEL_USER="muse-panel"
APP_DIR="/opt/muse-ops-panel"
DATA_DIR="/var/lib/muse-ops-panel"

[ "$(id -u)" = "0" ] || { echo "请以 root 运行: bash uninstall.sh" >&2; exit 1; }

# --- 1) 运维账号 muse-ops(本系统的核心,卸载即断 Muse 接入) ---
rm -f "/etc/sudoers.d/$OPS_USER" "/etc/ssh/sshd_config.d/$OPS_USER.conf" /var/log/muse-ops-sudo.log
if sshd -t 2>/dev/null; then systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true; fi
id "$OPS_USER" >/dev/null 2>&1 && userdel -r "$OPS_USER" 2>/dev/null || true
getent group "$OPS_USER" >/dev/null 2>&1 && groupdel "$OPS_USER" 2>/dev/null || true
echo "运维账号 $OPS_USER 已删除,Muse 不再能登录这台机器"

# --- 2) 旧版面板残留(如有,一并清理;没有则自动跳过) ---
if [ -d "$APP_DIR" ] || [ -d "$DATA_DIR" ] || id "$PANEL_USER" >/dev/null 2>&1 \
   || [ -f /etc/systemd/system/muse-ops-panel.service ] || [ -e /usr/local/bin/muse-panel-ctl ]; then
  systemctl disable --now muse-ops-panel.service 2>/dev/null || true
  rm -f /etc/systemd/system/muse-ops-panel.service
  rm -rf /etc/systemd/system/muse-ops-panel.service.d
  systemctl daemon-reload 2>/dev/null || true
  rm -f /usr/local/bin/muse-panel-ctl
  rm -f "/etc/sudoers.d/$PANEL_USER"
  rm -rf "$APP_DIR" "$DATA_DIR"
  id "$PANEL_USER" >/dev/null 2>&1 && userdel "$PANEL_USER" 2>/dev/null || true
  getent group "$PANEL_USER" >/dev/null 2>&1 && groupdel "$PANEL_USER" 2>/dev/null || true
  echo "检测到旧版面板残留,已一并清理(程序/服务/数据/面板账号)"
fi

echo "卸载完成"
