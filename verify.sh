#!/usr/bin/env bash
# MUSE 运维接入(AGENT 版) 独立自检(以 root 运行,只读,不改任何东西)
#   bash verify.sh
# 装好之后、或任何时候怀疑连不上时跑一遍,把输出整段发给 Muse 判断。
set -uo pipefail

OPS_USER="muse-ops"
PUBKEY_FRAG="AAAAC3NzaC1lZDI1NTE5AAAAIEcbZl+X1air4Z6dbom1PIMKSCr9Ns7/2dg8yFTRHM/"
SSH_DIR="/home/$OPS_USER/.ssh"

echo "==== MUSE AGENT 自检 ===="
echo "-- 系统 --"
uname -a
[ -f /etc/os-release ] && grep -E '^(PRETTY_NAME|ID)=' /etc/os-release
echo "-- 账号 --"
id "$OPS_USER" 2>/dev/null || echo "账号 $OPS_USER 不存在(没装或已卸载)"
awk -F: -v u="$OPS_USER" '$1==u{print "shadow 密码字段首字符:", substr($2,1,1), "(Alpine 必须是 *;Debian 系 ! 正常)"}' /etc/shadow 2>/dev/null
echo "-- 公钥与权限 --"
if [ -f "$SSH_DIR/authorized_keys" ]; then
  grep -q "$PUBKEY_FRAG" "$SSH_DIR/authorized_keys" && echo "公钥:已写入" || echo "公钥:未找到 Muse 的公钥"
  ls -ld "$SSH_DIR" "$SSH_DIR/authorized_keys"
else
  echo "authorized_keys 不存在"
fi
echo "-- sudo --"
[ -f "/etc/sudoers.d/$OPS_USER" ] && echo "sudoers 文件:在" || echo "sudoers 文件:无"
su - "$OPS_USER" -c 'sudo -n true' >/dev/null 2>&1 && echo "$OPS_USER sudo -n:可用" || echo "$OPS_USER sudo -n:不可用"
echo "-- sshd --"
sshd -t 2>&1 && echo "sshd -t:通过"
sshd -T -C "user=$OPS_USER" 2>/dev/null | grep -iE '^(passwordauthentication|pubkeyauthentication|port) '
(ss -tln 2>/dev/null || netstat -tln 2>/dev/null || true) | grep -E '[:.](22)[[:space:]]' || echo "(22 端口监听未确认)"
echo "-- Tailscale(若已装) --"
if command -v tailscale >/dev/null 2>&1; then tailscale status 2>/dev/null | head -3; else echo "未装 tailscale"; fi
echo "==== 自检结束,把以上整段发给 Muse ===="
