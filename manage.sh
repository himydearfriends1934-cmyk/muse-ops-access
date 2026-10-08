#!/usr/bin/env bash
# MUSE 运维接入(AGENT 版) 管理菜单(以 root 运行)
#   bash manage.sh            打开菜单
#   bash manage.sh install    直接安装/更新
#   bash manage.sh uninstall  直接卸载(删除运维账号,需确认)
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" = "0" ] || { echo "请以 root 运行: bash manage.sh" >&2; exit 1; }

do_install() {
  bash "$DIR/install.sh"
}

do_uninstall() {
  echo "将彻底卸载 MUSE 运维接入(AGENT 版),包括:"
  echo "  - 运维账号 muse-ops 及其 sudo、sshd 配置(Muse 将无法再登录这台机器)"
  echo "  - 若有旧版面板残留(程序/服务/数据/面板账号),一并清理"
  read -r -p "确认卸载?输入 y 继续: " ans
  [ "$ans" = "y" ] || { echo "已取消"; return 0; }
  bash "$DIR/uninstall.sh"
}

case "${1:-}" in
  install) do_install ;;
  uninstall) do_uninstall ;;
  verify) bash "$DIR/verify.sh" ;;
  "")
    echo "========== MUSE 运维接入(AGENT 版) =========="
    echo "  1) 安装/更新"
    echo "  2) 卸载软件及依赖"
    echo "  3) 自检(只读,把输出发给 Muse 核验)"
    echo "  0) 退出"
    read -r -p "请选择 [0-3]: " choice || exit 0
    case "$choice" in
      1) do_install ;;
      2) do_uninstall ;;
      3) bash "$DIR/verify.sh" ;;
      *) echo "退出" ;;
    esac
    ;;
  *) echo "用法: bash manage.sh [install|uninstall|verify]" >&2; exit 2 ;;
esac
