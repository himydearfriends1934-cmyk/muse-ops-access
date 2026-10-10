#!/bin/sh
# MUSE 运维接入(AGENT 版) 引导脚本:给"连 bash/sshd 都没有"的机器打底
#   sh boot.sh
# 有些精简系统(Alpine 默认、最小化云镜像)没有 bash 或没装 sshd,直接跑
# install.sh 会卡在第一步。这个脚本用 POSIX sh 写成:先按发行版家族把
# bash、openssh、sudo、curl 补齐,再转交 install.sh 完成正式安装。
set -eu

[ "$(id -u)" = "0" ] || { echo "请以 root 运行: sh boot.sh" >&2; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"

OS_ID=""; OS_LIKE=""
osrel="${MUSE_OS_RELEASE_FILE:-/etc/os-release}"
if [ -f "$osrel" ]; then
  OS_ID="$(grep -E '^ID=' "$osrel" | head -1 | cut -d= -f2- | tr -d '"')"
  OS_LIKE="$(grep -E '^ID_LIKE=' "$osrel" | head -1 | cut -d= -f2- | tr -d '"')"
fi
FAMILY="unknown"
case " $OS_ID $OS_LIKE " in
  *" alpine "*) FAMILY="alpine" ;;
  *" debian "*|*" ubuntu "*) FAMILY="debian" ;;
  *" rhel "*|*" fedora "*|*" centos "*) FAMILY="rhel" ;;
  *" arch "*) FAMILY="arch" ;;
  *" suse "*) FAMILY="suse" ;;
esac
[ "$FAMILY" = "unknown" ] && [ -f /etc/alpine-release ] && FAMILY="alpine"
echo "boot: 发行版家族=$FAMILY (ID=$OS_ID)"

need=""
command -v bash >/dev/null 2>&1 || need="$need bash"
command -v sshd >/dev/null 2>&1 || need="$need sshd"
command -v sudo >/dev/null 2>&1 || need="$need sudo"
command -v curl >/dev/null 2>&1 || need="$need curl"

if [ -n "$need" ]; then
  echo "boot: 缺少:$need,按 $FAMILY 的包管理器补齐..."
  case "$FAMILY" in
    debian) apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bash openssh-server sudo curl ;;
    alpine) apk add --no-cache bash openssh sudo curl ;;
    rhel)
      if command -v dnf >/dev/null 2>&1; then dnf install -y bash openssh-server sudo curl
      else yum install -y bash openssh-server sudo curl; fi ;;
    arch) pacman -Sy --noconfirm bash openssh sudo curl ;;
    suse) zypper --non-interactive install bash openssh sudo curl ;;
    *)
      echo "boot: 未识别的发行版,请手动装好 bash、openssh-server、sudo、curl 后直接跑 bash install.sh" >&2
      exit 1 ;;
  esac
fi

command -v bash >/dev/null 2>&1 || { echo "boot: bash 仍不可用,无法继续" >&2; exit 1; }

# 管道单文件运行(如 curl | sh)时同目录下没有 install.sh,从仓库直接拉取正式安装脚本
if [ ! -f "$DIR/install.sh" ]; then
  echo "boot: 未发现同目录 install.sh,从 GitHub 拉取..."
  curl -fsSL "https://raw.githubusercontent.com/himydearfriends1934-cmyk/muse-ops-access/main/install.sh" -o "$DIR/install.sh" \
    || { echo "boot: 下载 install.sh 失败,请检查网络后重试" >&2; exit 1; }
fi

echo "boot: 依赖就绪,转交 install.sh"
exec bash "$DIR/install.sh" "$@"
