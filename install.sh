#!/usr/bin/env bash
# MUSE 运维接入系统 一键安装(在目标 VPS 上以 root 运行)
#   bash install.sh
# 做四件事:① 建运维账号 muse-ops(密钥登录+sudo,供 Muse 经 SSH 接入)
#          ② 装面板到 /opt/muse-ops-panel,数据在 /var/lib/muse-ops-panel
#          ③ 注册 systemd 服务 muse-ops-panel(默认端口 13628)
#          ④ 让你现场设置面板管理员密码(只存哈希在本机,Muse 不知道)
set -euo pipefail

PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEcbZl+X1air4Z6dbom1PIMKSCr9Ns7/2dg8yFTRHM/2 hatch"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="/opt/muse-ops-panel"
DATA_DIR="/var/lib/muse-ops-panel"
PANEL_USER="muse-panel"
OPS_USER="muse-ops"
PORT="${MUSE_PANEL_PORT:-13628}"

[ "$(id -u)" = "0" ] || { echo "请以 root 运行: bash install.sh" >&2; exit 1; }

# --- 0) Python 3 ---
if ! command -v python3 >/dev/null 2>&1; then
  echo "未找到 python3,尝试安装..."
  if command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y -qq python3 >/dev/null
  elif command -v dnf >/dev/null 2>&1; then dnf install -y python3 >/dev/null
  elif command -v yum >/dev/null 2>&1; then yum install -y python3 >/dev/null
  else echo "请先手动安装 python3" >&2; exit 1; fi
fi
echo "python3: $(python3 --version)"

# --- 1) 运维账号 muse-ops(给 Muse 的 SSH 接入口) ---
if ! id "$OPS_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$OPS_USER"
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

# --- 2) 面板程序与运行账号 ---
id "$PANEL_USER" >/dev/null 2>&1 \
  || useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$PANEL_USER" 2>/dev/null \
  || useradd --system --home-dir "$DATA_DIR" --shell /bin/false "$PANEL_USER"
usermod -aG "$PANEL_USER" "$OPS_USER"  # 让 Muse 经 SSH 能读写面板数据库
mkdir -p "$APP_DIR" "$DATA_DIR"
cp -r "$SRC_DIR/panel/." "$APP_DIR/"
rm -rf "$APP_DIR/__pycache__"
chmod -R a+rX "$APP_DIR"
chmod 755 "$APP_DIR/server.py" "$APP_DIR/ctl.py"
ln -sf "$APP_DIR/ctl.py" /usr/local/bin/muse-panel-ctl
chown -R "$PANEL_USER:$PANEL_USER" "$DATA_DIR"
chmod 2770 "$DATA_DIR"

# --- 3) 管理员密码与数据库 ---
if [ -f "$DATA_DIR/panel.db" ]; then
  echo "检测到已有面板数据,保留(密码不变;如需重置密码见 README)"
else
  read -r -s -p "设置面板管理员密码(至少 8 位,用户名固定 admin): " PW1; echo
  [ "${#PW1}" -ge 8 ] || { echo "密码太短" >&2; exit 1; }
  MUSE_PANEL_INIT_PW="$PW1" runuser -u "$PANEL_USER" -- python3 "$APP_DIR/server.py" --init --db "$DATA_DIR/panel.db"
  unset PW1
fi
chmod 660 "$DATA_DIR/panel.db" 2>/dev/null || true

# --- 4) systemd 服务 ---
cat > /etc/systemd/system/muse-ops-panel.service <<EOF
[Unit]
Description=MUSE Ops Access Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$PANEL_USER
Group=$PANEL_USER
ExecStart=/usr/bin/python3 $APP_DIR/server.py --port $PORT --db $DATA_DIR/panel.db
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now muse-ops-panel.service \
  || echo "警告: systemd 启动失败,请看 journalctl -u muse-ops-panel,或手动: python3 $APP_DIR/server.py --port $PORT --db $DATA_DIR/panel.db"

PUBIP="$(curl -s --max-time 5 https://api.ipify.org || true)"
SSHD_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
echo
echo "==================== 安装完成 ===================="
echo "面板地址: http://${PUBIP:-<这台机器的IP>}:$PORT/   用户名: admin"
echo "请把下面三行发给 Muse,他接入后你们就在面板里沟通:"
echo "  IP: ${PUBIP:-（没探测到，填公网 IP）}"
echo "  SSH端口: ${SSHD_PORT:-22}"
echo "  账号: $OPS_USER"
echo "提醒: 若云厂商有安全组/防火墙,请放行 ${PORT}/tcp(建议只对你自己的 IP 放行)"
echo "吊销 Muse 访问: userdel -r $OPS_USER,或删 /home/$OPS_USER/.ssh/authorized_keys"
echo "卸载: bash uninstall.sh(加 --purge 连数据和运维账号一并删干净)"
