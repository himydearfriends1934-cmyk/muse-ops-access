#!/usr/bin/env bash
# MUSE 运维接入系统 一键卸载(以 root 运行)
#   bash uninstall.sh           卸载面板程序与服务(保留 /var/lib/muse-ops-panel 数据与 muse-ops 运维账号)
#   bash uninstall.sh --purge   连数据、面板账号、muse-ops 运维账号与 sudo/sshd 配置一并删干净
set -euo pipefail

APP_DIR="/opt/muse-ops-panel"
DATA_DIR="/var/lib/muse-ops-panel"
PANEL_USER="muse-panel"
OPS_USER="muse-ops"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

[ "$(id -u)" = "0" ] || { echo "请以 root 运行: bash uninstall.sh" >&2; exit 1; }

systemctl disable --now muse-ops-panel.service 2>/dev/null || true
rm -f /etc/systemd/system/muse-ops-panel.service
systemctl daemon-reload 2>/dev/null || true
rm -f /usr/local/bin/muse-panel-ctl
rm -f /etc/sudoers.d/muse-panel
rm -rf "$APP_DIR"
id "$PANEL_USER" >/dev/null 2>&1 && userdel "$PANEL_USER" 2>/dev/null || true
getent group "$PANEL_USER" >/dev/null 2>&1 && groupdel "$PANEL_USER" 2>/dev/null || true
echo "面板程序与服务已卸载"

if [ "$PURGE" = "1" ]; then
  rm -rf "$DATA_DIR"
  rm -f "/etc/sudoers.d/$OPS_USER" "/etc/ssh/sshd_config.d/$OPS_USER.conf" /var/log/muse-ops-sudo.log
  if sshd -t 2>/dev/null; then systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true; fi
  id "$OPS_USER" >/dev/null 2>&1 && userdel -r "$OPS_USER" 2>/dev/null || true
  getent group "$OPS_USER" >/dev/null 2>&1 && groupdel "$OPS_USER" 2>/dev/null || true
  getent group "$PANEL_USER" >/dev/null 2>&1 && groupdel "$PANEL_USER" 2>/dev/null || true
  echo "已彻底清除:数据目录、运维账号 $OPS_USER 及其授权全部删除,Muse 不再能登录这台机器"
else
  echo "已保留:$DATA_DIR(对话与审计数据)"
  echo "已保留:运维账号 $OPS_USER(Muse 仍可 SSH 登录;如需一并清除,运行 bash uninstall.sh --purge)"
fi
