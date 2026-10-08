#!/usr/bin/env bash
# MUSE 运维接入(AGENT 版) 一键安装(在目标 VPS 上以 root 运行)
#   bash install.sh
# 只做一件事:建运维账号 muse-ops(密钥登录 + sudo 留痕),供 Muse 经 SSH 接入。
# Muse 不知道你的任何密码:muse-ops 密码锁定、禁密码登录,只认下面这把公钥。
# 支持 Debian/Ubuntu(systemd)、RHEL 系、Alpine(OpenRC)。装完自动跑一遍自检并打印,
# 把输出整段发给 Muse,他核验全绿后再连接,避免装完才发现连不上。
set -euo pipefail

PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEcbZl+X1air4Z6dbom1PIMKSCr9Ns7/2dg8yFTRHM/2 hatch"
OPS_USER="muse-ops"

[ "$(id -u)" = "0" ] || { echo "请以 root 运行: bash install.sh" >&2; exit 1; }

ALPINE=0
[ -f /etc/alpine-release ] && ALPINE=1

say() { echo "$*"; }
ok()  { echo "[OK] $*"; }
bad() { echo "[FAIL] $*"; FAILURES=$((FAILURES+1)); }
FAILURES=0

reload_sshd() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service sshd reload 2>/dev/null || rc-service openssh reload 2>/dev/null || true
  elif [ -x /etc/init.d/sshd ]; then
    /etc/init.d/sshd reload 2>/dev/null || true
  fi
}

ensure_sudo() {
  command -v sudo >/dev/null 2>&1 && return 0
  if [ "$ALPINE" = "1" ] && command -v apk >/dev/null 2>&1; then
    apk add --no-cache sudo >/dev/null 2>&1 || true
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get install -y -qq sudo >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y sudo >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y sudo >/dev/null 2>&1 || true
  fi
  command -v sudo >/dev/null 2>&1
}

# --- 0) 前置检查 ---
sshd -t >/dev/null 2>&1 || say "提示:sshd 当前配置校验不过,装完请看自检结果"
ensure_sudo || say "警告:未找到 sudo 且自动安装失败,muse-ops 将没有 sudo(SSH 登录不受影响)"

# --- 1) 运维账号 muse-ops(给 Muse 的 SSH 接入口) ---
if ! id "$OPS_USER" >/dev/null 2>&1; then
  if [ "$ALPINE" = "1" ]; then
    adduser -D -s /bin/bash "$OPS_USER" 2>/dev/null || adduser -D -s /bin/sh "$OPS_USER"
    # Alpine 的 sshd(无 PAM)会拒绝 shadow 里带 ! 的锁定账号,连公钥也进不去;改成 * 才行
    command -v usermod >/dev/null 2>&1 && usermod -p '*' "$OPS_USER" 2>/dev/null || true
    sed -i "s|^\($OPS_USER\):!|\1:*|" /etc/shadow 2>/dev/null || true
  else
    if getent group "$OPS_USER" >/dev/null 2>&1; then
      useradd -g "$OPS_USER" -m -s /bin/bash "$OPS_USER"
    else
      useradd -m -s /bin/bash "$OPS_USER"
    fi
    passwd -l "$OPS_USER" >/dev/null
  fi
  say "已创建运维账号 $OPS_USER"
fi
SSH_DIR="/home/$OPS_USER/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$SSH_DIR/authorized_keys"
grep -qxF "$PUBKEY" "$SSH_DIR/authorized_keys" \
  || echo "$PUBKEY" >> "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$OPS_USER:$OPS_USER" "/home/$OPS_USER" 2>/dev/null || chown -R "$OPS_USER" "/home/$OPS_USER"
command -v restorecon >/dev/null 2>&1 && restorecon -R "$SSH_DIR" >/dev/null 2>&1 || true

if command -v sudo >/dev/null 2>&1; then
  mkdir -p /etc/sudoers.d
  cat > "/etc/sudoers.d/$OPS_USER" <<EOF
Defaults:$OPS_USER logfile="/var/log/muse-ops-sudo.log"
$OPS_USER ALL=(ALL) NOPASSWD: ALL
EOF
  chmod 440 "/etc/sudoers.d/$OPS_USER"
  if command -v visudo >/dev/null 2>&1; then visudo -cf "/etc/sudoers.d/$OPS_USER" >/dev/null; fi
fi

SSHD_BLOCK="Match User $OPS_USER
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes"
SSHD_CFG_WRITTEN="none"
if [ "$ALPINE" = "1" ]; then
  # Alpine 的 sshd_config 通常不 Include sshd_config.d,直接写主配置(带标记防重复)
  if ! grep -q "MUSE-OPS-BEGIN" /etc/ssh/sshd_config 2>/dev/null; then
    printf '\n# MUSE-OPS-BEGIN\n%s\n# MUSE-OPS-END\n' "$SSHD_BLOCK" >> /etc/ssh/sshd_config
  fi
  SSHD_CFG_WRITTEN="sshd_config"
else
  mkdir -p /etc/ssh/sshd_config.d
  printf '%s\n' "$SSHD_BLOCK" > "/etc/ssh/sshd_config.d/$OPS_USER.conf"
  SSHD_CFG_WRITTEN="sshd_config.d"
fi
if sshd -t 2>/dev/null; then
  reload_sshd
else
  [ "$SSHD_CFG_WRITTEN" = "sshd_config.d" ] && rm -f "/etc/ssh/sshd_config.d/$OPS_USER.conf"
  say "警告:sshd 配置校验未过(账号与公钥仍可用);若是 Alpine 主配置块,请把 sshd -t 的报错发给 Muse"
fi

# --- 2) 装后自检(打印给 Muse 核验) ---
say ""
say "==================== 安装自检 ===================="
id "$OPS_USER" >/dev/null 2>&1 && ok "账号 $OPS_USER 存在" || bad "账号 $OPS_USER 不存在"
if grep -qxF "$PUBKEY" "$SSH_DIR/authorized_keys" 2>/dev/null; then ok "公钥已写入 authorized_keys"; else bad "公钥未写入 authorized_keys"; fi
[ "$(stat -c %a "$SSH_DIR" 2>/dev/null || stat -f %Lp "$SSH_DIR" 2>/dev/null)" = "700" ] \
  && ok ".ssh 目录权限 700" || bad ".ssh 目录权限不是 700(实际 $(stat -c %a "$SSH_DIR" 2>/dev/null))"
[ "$(stat -c %a "$SSH_DIR/authorized_keys" 2>/dev/null)" = "600" ] \
  && ok "authorized_keys 权限 600" || bad "authorized_keys 权限不是 600"
SHADOW2="$(awk -F: -v u="$OPS_USER" '$1==u{print $2}' /etc/shadow 2>/dev/null)"
case "$SHADOW2" in
  '!'*)
    if [ "$ALPINE" = "1" ]; then
      bad "密码字段带 !(Alpine 无 PAM 的 sshd 会拒绝公钥登录,需改成 *)"
    else
      ok "密码字段为锁定态(此系统走 PAM,公钥登录不受影响)"
    fi ;;
  '*'*) ok "密码字段为 *(禁密码但不挡公钥)" ;;
  *) ok "密码字段形态可接受" ;;
esac
[ -f "/etc/sudoers.d/$OPS_USER" ] && ok "sudoers 已配置(免密+日志)" || say "[提示] 无 sudoers 配置:未装 sudo 或写入失败,muse-ops 无 sudo"
if command -v visudo >/dev/null 2>&1; then
  visudo -cf "/etc/sudoers.d/$OPS_USER" >/dev/null 2>&1 && ok "sudoers 语法校验通过" || bad "sudoers 语法校验失败"
fi
su - "$OPS_USER" -c 'sudo -n true' >/dev/null 2>&1 && ok "$OPS_USER 可免密 sudo" || say "[提示] $OPS_USER 暂时无法免密 sudo(无 sudo 或配置未生效)"
sshd -t >/dev/null 2>&1 && ok "sshd 配置校验通过" || bad "sshd 配置校验失败"
if sshd -T -C "user=$OPS_USER" 2>/dev/null | grep -qi '^passwordauthentication no'; then
  ok "sshd 对 $OPS_USER 的生效配置:禁密码登录"
else
  say "[提示] sshd 对 $OPS_USER 的生效配置未确认禁密码(以 sshd -T 实际输出为准,可发给 Muse 判断)"
fi
if (ss -tln 2>/dev/null || netstat -tln 2>/dev/null || true) | grep -q '[:.]22[[:space:]]'; then
  ok "sshd 正在监听 22 端口"
else
  say "[提示] 未从 22 端口确认 sshd 监听(自定义端口或 ss/netstat 不可用,可发给 Muse 判断)"
fi
PUBIP="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || wget -qO- --timeout=5 https://api.ipify.org 2>/dev/null || true)"
SSHD_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
[ "$FAILURES" = "0" ] && say "自检结论:全部通过,可以把下面信息发给 Muse 接入" \
                      || say "自检结论:有 $FAILURES 项 FAIL,把整段自检输出发给 Muse 处理"
say "=================================================="
say "  IP: ${PUBIP:-（没探测到，填这台机器的公网或 Tailscale IP）}"
say "  SSH端口: ${SSHD_PORT:-22}"
say "  账号: $OPS_USER"
say "吊销访问(随时,不需要 Muse 配合):删账号 $OPS_USER,或删 $SSH_DIR/authorized_keys 里的公钥"
say "卸载: bash uninstall.sh(连运维账号一并删干净)"
