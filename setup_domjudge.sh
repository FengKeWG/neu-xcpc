#!/usr/bin/env bash
set -euo pipefail

# === 可按需修改的参数 ===
TZ_REGION="Asia/Shanghai"
DEB_MIRROR_DEBIAN="https://mirrors.aliyun.com/debian"
DEB_MIRROR_UBUNTU="https://mirrors.aliyun.com/ubuntu/"
DOMJUDGE_SRC_DIR="/opt/domjudge-src"
DOMJUDGE_PREFIX="/opt/domjudge"         # 安装前缀（安装后 domserver/judgehost 都在此）
XCPC_TOOLS_DIR="/opt/xcpc-tools"        # 若你有 xcpc-tools Linux 二进制放这里（可选）
XCPC_TOOLS_BIN="${XCPC_TOOLS_DIR}/xcpc-tools"
XCPC_TOOLS_SERVICE_NAME="xcpc-tools"
SERVER_NAME="_"                         # Nginx server_name，默认为 _

log() { echo -e "\033[1;32m[+] $*\033[0m"; }
warn(){ echo -e "\033[1;33m[!] $*\033[0m"; }
die() { echo -e "\033[1;31m[✗] $*\033[0m"; exit 1; }

require_root_or_sudo() {
  if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "需要 root 或 sudo 权限"
  fi
}
SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"

require_root_or_sudo

log "设置时区与时间同步"
$SUDO timedatectl set-timezone "$TZ_REGION" || true
$SUDO timedatectl set-ntp true || true

log "安装基础依赖（编译、PHP、Nginx、MariaDB、Composer、Java、debootstrap、cgroup 等）"
$SUDO apt-get update -y
$SUDO apt-get install -y \
  build-essential autoconf automake libtool bison flex pkg-config \
  php php-fpm php-cli php-mbstring php-xml php-curl php-zip php-gd php-mysql \
  mariadb-server nginx composer \
  default-jre-headless openjdk-17-jdk \
  debootstrap libcgroup-dev \
  python3 pypy3 curl git ca-certificates lsb-release

log "准备 DOMjudge 源码目录: ${DOMJUDGE_SRC_DIR}"
if [[ ! -d "$DOMJUDGE_SRC_DIR" ]]; then
  $SUDO mkdir -p "$DOMJUDGE_SRC_DIR"
  $SUDO chown -R "$USER":"$USER" "$DOMJUDGE_SRC_DIR"
  log "克隆 DOMjudge 源码（如你的网络慢可手动提前放置源码到 ${DOMJUDGE_SRC_DIR}）"
  git clone --depth=1 https://github.com/DOMjudge/domjudge.git "$DOMJUDGE_SRC_DIR"
else
  warn "已存在 ${DOMJUDGE_SRC_DIR}，跳过克隆"
fi

log "编译并安装 DOMjudge（domserver + judgehost）到 ${DOMJUDGE_PREFIX}"
pushd "$DOMJUDGE_SRC_DIR" >/dev/null
./configure --prefix="$DOMJUDGE_PREFIX"
make -j"$(nproc)"
$SUDO make install-domserver
$SUDO make install-judgehost
popd >/dev/null

log "生成密钥文件（DB/Admin/Symfony/REST）"
$SUDO "${DOMJUDGE_PREFIX}/domserver/etc/gen_all_secrets"

log "初始化数据库（通过本地 socket 以 root 连接，无需密码）"
$SUDO "${DOMJUDGE_PREFIX}/domserver/bin/dj_setup_database" -u root -s install

log "配置 Nginx 虚拟主机"
SITE_SRC="${DOMJUDGE_PREFIX}/domserver/etc/nginx-conf"
SITE_DST="/etc/nginx/sites-available/domjudge"
$SUDO cp -f "$SITE_SRC" "$SITE_DST"
# 调整 server_name（可选）
$SUDO sed -i "s/server_name .*/server_name ${SERVER_NAME};/" "$SITE_DST" || true
# 启用站点
$SUDO ln -sf "$SITE_DST" /etc/nginx/sites-enabled/domjudge
# 去掉默认站点（可选）
if [[ -e /etc/nginx/sites-enabled/default ]]; then $SUDO rm -f /etc/nginx/sites-enabled/default || true; fi
$SUDO nginx -t
$SUDO systemctl reload nginx

log "创建并构建评测 chroot（debootstrap，按宿主系统选择镜像）"
DISTRO="$(lsb_release -i -s || true)"
MIRROR="${DEB_MIRROR_DEBIAN}"
if [[ "$DISTRO" == "Ubuntu" ]]; then MIRROR="${DEB_MIRROR_UBUNTU}"; fi
$SUDO DEBMIRROR="$MIRROR" "${DOMJUDGE_PREFIX}/misc-tools/dj_make_chroot" -y

log "创建 cgroups（若服务存在则启用）"
if systemctl list-unit-files | grep -q create-cgroups.service; then
  $SUDO systemctl enable --now create-cgroups.service || true
fi

log "启动评测守护进程（2 个并发）"
if systemctl list-unit-files | grep -q 'domjudge-judgedaemon@'; then
  $SUDO systemctl enable --now domjudge-judgedaemon@1
  $SUDO systemctl enable --now domjudge-judgedaemon@2
else
  warn "未检测到 domjudge-judgedaemon@ systemd 单元，可手动运行：${DOMJUDGE_PREFIX}/judgehost/bin/judgedaemon -n 2"
fi

log "开启常用防火墙端口（80）"
if command -v ufw >/dev/null 2>&1; then
  $SUDO ufw allow 80/tcp || true
fi

log "DOMjudge 初始管理员密码："
$SUDO cat "${DOMJUDGE_PREFIX}/domserver/etc/initial_admin_password.secret" || true
echo
echo "访问地址: http://<服务器IP>/"
echo

# === 可选：托管 XCPC-TOOLS 二进制为 systemd 服务（如你已将二进制放到 ${XCPC_TOOLS_BIN} 并准备好 ${XCPC_TOOLS_DIR}/config.yaml）===
if [[ -x "$XCPC_TOOLS_BIN" && -f "${XCPC_TOOLS_DIR}/config.yaml" ]]; then
  log "检测到 XCPC-TOOLS 二进制与配置，创建 systemd 服务"
  $SUDO tee "/etc/systemd/system/${XCPC_TOOLS_SERVICE_NAME}.service" >/dev/null <<EOF
[Unit]
Description=XCPC-TOOLS Server
After=network.target

[Service]
WorkingDirectory=${XCPC_TOOLS_DIR}
ExecStart=${XCPC_TOOLS_BIN}
Restart=always
Environment=TZ=${TZ_REGION}
# 如需以特定用户运行，取消下一行注释并修改用户名
# User=ubuntu

[Install]
WantedBy=multi-user.target
EOF
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now "${XCPC_TOOLS_SERVICE_NAME}.service"
  log "XCPC-TOOLS 已尝试启动，默认端口见你的 ${XCPC_TOOLS_DIR}/config.yaml（默认 5283）"
else
  warn "未检测到 ${XCPC_TOOLS_BIN} 或配置 ${XCPC_TOOLS_DIR}/config.yaml，跳过 XCPC-TOOLS 托管（可稍后自行放置后创建服务）"
fi

log "全部完成。建议操作："
echo "- 浏览器打开 http://<服务器IP>/，用上面的初始密码登录 DOMjudge 后台"
echo "- 后台新增比赛/导入题目；Judgehosts 页面应显示在线"
echo "- 如需托管 XCPC-TOOLS，请将二进制置于 ${XCPC_TOOLS_BIN} 并配置 ${XCPC_TOOLS_DIR}/config.yaml 后重启服务：sudo systemctl restart ${XCPC_TOOLS_SERVICE_NAME}"


