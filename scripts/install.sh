#!/usr/bin/env bash

# 若不是用 bash 解释器执行，自动用 bash 重新执行自身（兼容被 sh 调用的场景）
if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi

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
HTTP_PORT="${HTTP_PORT:-11451}"

set_apt_mirror_tuna() {
  local codename
  codename=$(lsb_release -cs 2>/dev/null || { . /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}"; })
  if [[ -z "$codename" ]]; then
    warn "无法检测发行版代号，跳过切换清华镜像。"
    return 0
  fi
  log "切换 APT 源为清华镜像 ($codename)"
  cat >/etc/apt/sources.list <<EOF
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $codename main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $codename-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $codename-backports main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $codename-security main restricted universe multiverse
EOF
}

main() {
  require_root
  check_os

  if [[ ! -d "$DOMJUDGE_SRC_DIR" ]]; then
    err "未找到 DOMjudge 源码目录：$DOMJUDGE_SRC_DIR"
    exit 1
  fi

  log "更新 APT 源并安装基础依赖..."
  export DEBIAN_FRONTEND=noninteractive
  set_apt_mirror_tuna
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl git software-properties-common \
    make pkg-config gcc g++ zip unzip pv acl \
    mariadb-server mariadb-client \
    nginx \
    php-fpm php-cli php-curl php-gd php-intl php-mbstring php-mysql php-xml php-zip php-bcmath \
    composer \
    python3-yaml \
    debootstrap libcgroup-dev lsof procps \
    lsb-release

  if command -v composer >/dev/null 2>&1; then
    log "切换 Composer 源为清华镜像"
    COMPOSER_ALLOW_SUPERUSER=1 composer -n config -g repos.packagist composer https://mirrors.tuna.tsinghua.edu.cn/composer/ || true
  fi

  # 将 composer 设为非交互且允许 root，以避免构建过程阻塞
  export COMPOSER_NO_INTERACTION=1
  export COMPOSER_ALLOW_SUPERUSER=1

  # 避免与 Nginx 冲突：停用并屏蔽 Apache（若存在），并移除 Apache PHP 模块
  if systemctl list-unit-files | grep -q '^apache2.service'; then
    log "检测到 Apache，停止并禁用以避免占用 80 端口"
    systemctl stop apache2 || true
    systemctl disable apache2 || true
    systemctl mask apache2 || true
  fi
  if dpkg -l | grep -q '^ii  libapache2-mod-php'; then
    log "移除 libapache2-mod-php* 以避免与 php-fpm 冲突"
    apt-get purge -y libapache2-mod-php* || true
    apt-get autoremove -y || true
  fi

  if ! timedatectl status >/dev/null 2>&1; then
    warn "无法使用 timedatectl 配置时区，将跳过。"
  else
    log "设置时区为 $TIMEZONE"
    timedatectl set-timezone "$TIMEZONE" || true
  fi

  log "启用系统时间同步（NTP）"
  if systemctl list-unit-files | grep -q '^systemd-timesyncd.service'; then
    systemctl enable --now systemd-timesyncd || true
  else
    apt-get install -y chrony
    systemctl enable --now chrony || true
  fi

  log "启动并开机自启 MariaDB 与 Nginx"
  systemctl enable --now mariadb
  systemctl enable --now nginx

  log "配置 PHP-FPM 服务名"
  local PHP_VER PHP_FPM_SERVICE
  PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
  PHP_FPM_SERVICE="php${PHP_VER}-fpm"
  # 仅启用，不立即启动；待写入 DOMjudge 池配置后再启动
  systemctl enable "$PHP_FPM_SERVICE" || true

  log "构建并安装 DOMjudge (domserver + judgehost) 到 $DOMJUDGE_PREFIX"
  # 确保 domjudge 系统用户存在（作为 DOMjudge 主进程与 judgedaemon 运行用户）
  if ! id -u domjudge >/dev/null 2>&1; then
    useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin domjudge
  fi

  # 修正执行权限与潜在的 CRLF 换行，避免 Permission denied
  chmod +x "$DOMJUDGE_SRC_DIR/configure" || true
  chmod +x "$DOMJUDGE_SRC_DIR/etc/gen_all_secrets" || true
  # 为包含 shebang 的脚本赋予可执行权限
  grep -rIl '^#!' "$DOMJUDGE_SRC_DIR" | xargs -r chmod +x || true
  # 纠正常见的 CRLF 换行问题（若存在）
  sed -i 's/\r$//' "$DOMJUDGE_SRC_DIR/configure" "$DOMJUDGE_SRC_DIR/etc/gen_all_secrets" || true

  cd "$DOMJUDGE_SRC_DIR"
  # 生成本地 baseurl（端口为 80 时省略端口）
  local BASEURL="http://127.0.0.1/domjudge/"
  if [[ "$HTTP_PORT" != "80" ]]; then
    BASEURL="http://127.0.0.1:${HTTP_PORT}/domjudge/"
  fi
  bash ./configure --prefix="$DOMJUDGE_PREFIX" \
    --with-domjudge-user=domjudge \
    --with-webserver-group=www-data \
    --with-baseurl="${BASEURL}"
  COMPOSER_NO_INTERACTION=1 COMPOSER_ALLOW_SUPERUSER=1 make -j"$(nproc)" domserver judgehost
  # 幂等：若上次安装已创建过符号链接，先删除以避免 ln 报错
  if [[ -e "$DOMJUDGE_PREFIX/domserver/bin/dj_console" ]]; then
    rm -f "$DOMJUDGE_PREFIX/domserver/bin/dj_console" || true
  fi
  COMPOSER_NO_INTERACTION=1 COMPOSER_ALLOW_SUPERUSER=1 make install-domserver
  COMPOSER_NO_INTERACTION=1 COMPOSER_ALLOW_SUPERUSER=1 make install-judgehost

  log "配置 Nginx 与 PHP-FPM 以提供 DOMjudge Web 界面"
  mkdir -p /etc/nginx/sites-enabled
  rm -f /etc/nginx/sites-enabled/default || true
  ln -sf "$DOMJUDGE_PREFIX/domserver/etc/nginx-conf" /etc/nginx/sites-enabled/domjudge
  ln -sf "$DOMJUDGE_PREFIX/domserver/etc/domjudge-fpm.conf" \
    "/etc/php/${PHP_VER}/fpm/pool.d/domjudge.conf"
  # 修改 Nginx 监听端口为 HTTP_PORT（默认 12345）
  sed -i -E "s/listen [0-9]+;/listen ${HTTP_PORT};/g" "$DOMJUDGE_PREFIX/domserver/etc/nginx-conf"
  sed -i -E "s/listen \[::\]:[0-9]+;/listen [::]:${HTTP_PORT};/g" "$DOMJUDGE_PREFIX/domserver/etc/nginx-conf"
  # 测试 PHP-FPM 配置并启动
  local PHP_FPM_BIN=""
  if command -v "php-fpm${PHP_VER}" >/dev/null 2>&1; then
    PHP_FPM_BIN="php-fpm${PHP_VER}"
  elif command -v php-fpm >/dev/null 2>&1; then
    PHP_FPM_BIN="php-fpm"
  fi
  if [[ -n "$PHP_FPM_BIN" ]]; then
    $PHP_FPM_BIN -t || { err "PHP-FPM 配置测试失败，请检查 /etc/php/${PHP_VER}/fpm/ 下配置"; exit 1; }
  fi
  systemctl restart "$PHP_FPM_SERVICE" || {
    warn "PHP-FPM 启动失败，输出最近日志以便排查";
    journalctl -xeu "$PHP_FPM_SERVICE" --no-pager -n 100 || true;
    exit 1;
  }
  if ! nginx -t; then
    nginx -t || true
    err "Nginx 配置测试失败，请根据上面的错误信息修复后重试。"
    exit 1
  fi
  systemctl reload nginx || { warn "Nginx reload 失败，尝试 restart"; systemctl restart nginx; }

  # 如启用了 ufw/firewalld，则放行 HTTP_PORT
  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
      ufw allow "${HTTP_PORT}/tcp" || true
    fi
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${HTTP_PORT}/tcp" || true
    firewall-cmd --reload || true
  fi

  log "生成 DOMjudge 密钥与初始配置"
  "$DOMJUDGE_PREFIX/domserver/bin/dj_setup_database" genpass

  log "初始化数据库（幂等，已安装则跳过）"
  if "$DOMJUDGE_PREFIX/domserver/bin/dj_setup_database" -q -s status; then
    log "检测到数据库已初始化，跳过 install。"
  else
    if ! "$DOMJUDGE_PREFIX/domserver/bin/dj_setup_database" -q -s bare-install; then
      warn "数据库初始化失败，请检查 MariaDB 运行状态与 root socket 认证。"
      exit 1
    fi
  fi

  log "安装 sudoers 规则 (runguard 等)"
  install -m 0440 "$DOMJUDGE_PREFIX/judgehost/etc/sudoers-domjudge" /etc/sudoers.d/domjudge

  log "生成评测 chroot (Ubuntu，与国内镜像) — 时间较长"
  # 使用宿主发行版与架构；指定国内镜像以加速
  DEBMIRROR="$UBUNTU_MIRROR" "$DOMJUDGE_PREFIX/judgehost/bin/dj_make_chroot" -y -m "$UBUNTU_MIRROR"

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

  # 修正评测机 API 地址，确保使用实际 HTTP 端口（默认 12345）
  if [[ -f "$DOMJUDGE_PREFIX/judgehost/etc/restapi.secret" ]]; then
    awk -v port="$HTTP_PORT" 'BEGIN{OFS="\t"}
      $0 ~ /^\s*#/ {print; next}
      NF>=4 {print $1, "http://127.0.0.1:" port "/domjudge/api", $3, $4; next}
      {print}
    ' "$DOMJUDGE_PREFIX/judgehost/etc/restapi.secret" > "$DOMJUDGE_PREFIX/judgehost/etc/restapi.secret.tmp" && \
    mv "$DOMJUDGE_PREFIX/judgehost/etc/restapi.secret.tmp" "$DOMJUDGE_PREFIX/judgehost/etc/restapi.secret" && \
    chown domjudge:domjudge "$DOMJUDGE_PREFIX/judgehost/etc/restapi.secret" && \
    chmod 600 "$DOMJUDGE_PREFIX/judgehost/etc/restapi.secret"
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
    # 将 server 指向本机 DOMjudge，使用 /domjudge 路径前缀（避免分隔符冲突，不用分组回溯）
    sed -E "s|^server:.*$|server: http://127.0.0.1:${HTTP_PORT}/domjudge|" \
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
  if [[ "$HTTP_PORT" = "80" ]]; then
    echo "- DOMjudge 访问: http://<服务器IP>/domjudge"
  else
    echo "- DOMjudge 访问: http://<服务器IP>:${HTTP_PORT}/domjudge"
  fi
  echo "- 初始管理员密码: $(cat "$DOMJUDGE_PREFIX/domserver/etc/initial_admin_password.secret")"
  echo "- REST API 凭据:   $DOMJUDGE_PREFIX/domserver/etc/restapi.secret (judgehost 使用)"
  echo "- XCPC-TOOLS:     http://<服务器IP>:5283"
  echo
  echo "如需更多 judgedaemon 实例："
  echo "  - 创建运行用户: useradd -d /nonexistent -g domjudge-run -M -s /bin/false domjudge-run-<N>"
  echo "  - 启动服务:      systemctl enable --now domjudge-judgedaemon@<N>.service"
}

main "$@"
