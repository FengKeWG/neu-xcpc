#!/usr/bin/env bash

set -Eeuo pipefail

log() { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err() { echo -e "\033[1;31m[✗]\033[0m $*" >&2; }

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    err "请以 root 身份运行：sudo bash $0"
    exit 1
  fi
}

check_os() {
  if ! command -v lsb_release >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y lsb-release
  fi
  local distro codename
  distro=$(lsb_release -is 2>/dev/null || echo "")
  codename=$(lsb_release -cs 2>/dev/null || echo "")
  if [[ "$distro" != "Ubuntu" ]]; then
    warn "检测到发行版: $distro ($codename)，此脚本仅在 Ubuntu 24 上测试通过。"
  fi
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
DOMJUDGE_SRC_DIR="$REPO_DIR/domjudge"
DOMJUDGE_PREFIX="/opt/domjudge"
XCPC_SRC_DIR="$REPO_DIR/xcpc-tools"
XCPC_INSTALL_DIR="/opt/xcpc-tools"
TIMEZONE="Asia/Shanghai"
UBUNTU_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu/"

main() {
  require_root
  check_os

  if [[ ! -d "$DOMJUDGE_SRC_DIR" ]]; then
    err "未找到 DOMjudge 源码目录：$DOMJUDGE_SRC_DIR"
    exit 1
  fi

  log "更新 APT 源并安装基础依赖..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    ca-certificates curl git software-properties-common \
    make pkg-config gcc g++ zip unzip pv \
    mariadb-server mariadb-client \
    nginx \
    php php-fpm php-cli php-curl php-gd php-intl php-mbstring php-mysql php-json php-xml php-zip php-bcmath \
    composer \
    ntp python3-yaml \
    debootstrap libcgroup-dev lsof procps \
    lsb-release

  if ! timedatectl status >/dev/null 2>&1; then
    warn "无法使用 timedatectl 配置时区，将跳过。"
  else
    log "设置时区为 $TIMEZONE"
    timedatectl set-timezone "$TIMEZONE" || true
  fi

  log "启动并开机自启 MariaDB 与 Nginx"
  systemctl enable --now mariadb
  systemctl enable --now nginx

  log "配置 PHP-FPM 服务名"
  local PHP_VER PHP_FPM_SERVICE
  PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
  PHP_FPM_SERVICE="php${PHP_VER}-fpm"
  systemctl enable --now "$PHP_FPM_SERVICE"

  log "构建并安装 DOMjudge (domserver + judgehost) 到 $DOMJUDGE_PREFIX"
  cd "$DOMJUDGE_SRC_DIR"
  ./configure --prefix="$DOMJUDGE_PREFIX"
  make -j"$(nproc)" domserver judgehost
  make install-domserver
  make install-judgehost

  log "配置 Nginx 与 PHP-FPM 以提供 DOMjudge Web 界面"
  mkdir -p /etc/nginx/sites-enabled
  rm -f /etc/nginx/sites-enabled/default || true
  ln -sf "$DOMJUDGE_PREFIX/etc/nginx-conf" /etc/nginx/sites-enabled/domjudge
  ln -sf "$DOMJUDGE_PREFIX/etc/domjudge-fpm.conf" \
    "/etc/php/${PHP_VER}/fpm/pool.d/domjudge.conf"
  systemctl reload "$PHP_FPM_SERVICE"
  systemctl reload nginx

  log "生成 DOMjudge 密钥与初始配置"
  "$DOMJUDGE_PREFIX/bin/dj_setup_database" genpass

  log "初始化数据库（socket 认证，非交互）"
  if ! "$DOMJUDGE_PREFIX/bin/dj_setup_database" -q -s install; then
    warn "数据库初始化失败，请检查 MariaDB 运行状态与 root socket 认证。"
    exit 1
  fi

  log "安装 sudoers 规则 (runguard 等)"
  install -m 0440 "$DOMJUDGE_PREFIX/etc/sudoers-domjudge" /etc/sudoers.d/domjudge

  log "生成评测 chroot (Ubuntu，与国内镜像) — 时间较长"
  # 使用宿主发行版与架构；指定国内镜像以加速
  DEBMIRROR="$UBUNTU_MIRROR" "$DOMJUDGE_PREFIX/bin/dj_make_chroot" -y -m "$UBUNTU_MIRROR"

  log "部署 judgehost 的 systemd 单元"
  # 编译后生成在源码树下的 .service 文件（非 .in）
  install -m 0644 "$DOMJUDGE_SRC_DIR/judge/create-cgroups.service" /etc/systemd/system/create-cgroups.service
  install -m 0644 "$DOMJUDGE_SRC_DIR/judge/domjudge-judgedaemon@.service" /etc/systemd/system/domjudge-judgedaemon@.service
  install -m 0644 "$DOMJUDGE_SRC_DIR/judge/domjudge-judgehost.target" /etc/systemd/system/domjudge-judgehost.target

  log "创建评测运行用户与组 (domjudge-run-0)"
  getent group domjudge-run >/dev/null 2>&1 || groupadd domjudge-run
  if ! id -u domjudge-run-0 >/dev/null 2>&1; then
    useradd -d /nonexistent -g domjudge-run -M -s /bin/false domjudge-run-0
  fi

  log "启用 cgroups 服务与启动 judgedaemon@0"
  systemctl daemon-reload
  systemctl enable --now create-cgroups.service
  # 默认 target 依赖 @0，可按需扩展更多核：编辑 /etc/systemd/system/domjudge-judgehost.target
  systemctl enable --now domjudge-judgedaemon@0.service

  log "部署 XCPC-TOOLS 到 $XCPC_INSTALL_DIR 并创建 systemd 服务"
  mkdir -p "$XCPC_INSTALL_DIR"
  if [[ -f "$XCPC_SRC_DIR/xcpc-tools-linux" ]]; then
    install -m 0755 "$XCPC_SRC_DIR/xcpc-tools-linux" "$XCPC_INSTALL_DIR/xcpc-tools-linux"
  else
    warn "未找到 $XCPC_SRC_DIR/xcpc-tools-linux，跳过二进制部署（如需可自行放置后重启服务）"
  fi
  if [[ -f "$XCPC_SRC_DIR/config.server.yaml" ]]; then
    # 将 server 指向本机 DOMjudge，使用 /domjudge 路径前缀
    sed -E \
      -e 's#^(server:).*$#\1 http://127.0.0.1/domjudge#' \
      "$XCPC_SRC_DIR/config.server.yaml" > "$XCPC_INSTALL_DIR/config.server.yaml"
  fi

  cat >/etc/systemd/system/xcpc-tools.service <<'UNIT'
[Unit]
Description=XCPC Tools Server
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/xcpc-tools
Environment=TZ=Asia/Shanghai
ExecStart=/opt/xcpc-tools/xcpc-tools-linux
Restart=on-failure
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  if [[ -x "$XCPC_INSTALL_DIR/xcpc-tools-linux" ]]; then
    systemctl enable --now xcpc-tools.service
  else
    warn "XCPC-TOOLS 可执行文件不存在或无执行权限，未启动服务。"
  fi

  log "完成！关键信息如下："
  echo "- DOMjudge 访问: http://<服务器IP>/domjudge"
  echo "- 初始管理员密码: $(cat "$DOMJUDGE_PREFIX/etc/initial_admin_password.secret")"
  echo "- REST API 凭据:   $DOMJUDGE_PREFIX/etc/restapi.secret (judgehost 使用)"
  echo "- XCPC-TOOLS:     systemctl status xcpc-tools.service (端口由二进制决定，默认行为请参见配置)"
  echo
  echo "如需更多 judgedaemon 实例："
  echo "  - 创建运行用户: useradd -d /nonexistent -g domjudge-run -M -s /bin/false domjudge-run-<N>"
  echo "  - 启动服务:      systemctl enable --now domjudge-judgedaemon@<N>.service"
}

main "$@"
