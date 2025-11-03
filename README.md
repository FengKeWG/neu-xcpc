## 方式1：非 Docker 部署（Ubuntu 24.04 裸机）

1) 一键安装（默认端口 11451）

```bash
git clone https://github.com/FengKeWG/neu-xcpc.git
cd neu-xcpc
bash scripts/install.sh
```

- 访问 DOMjudge：`http://<服务器IP>:11451/domjudge`
- 初始管理员密码：`/opt/domjudge/domserver/etc/initial_admin_password.secret`
- 评测机：自动安装并启动 `domjudge-judgedaemon@0`，`/opt/domjudge/judgehost/etc/restapi.secret` 自动匹配端口
- 访问 XCPC-TOOLS：`http://<服务器IP>:5283`
- XCPC-TOOLS: 配置在 `/opt/xcpc-tools/config.server.yaml`
- 自定义端口：设置环境变量 `HTTP_PORT=<端口>` 后再运行脚本

---

## 方式2：Docker 部署

### 1) 准备宿主目录与权限

```bash
git clone https://github.com/FengKeWG/neu-xcpc.git
cd neu-xcpc
sudo chown -R 1000:1000 ./domjudge ./xcpc-tools
sudo chmod 755 ./domjudge ./xcpc-tools
sudo chmod +x ./xcpc-tools/xcpc-tools-linux
sudo bash -lc 'grep -rIl "^#!" ./domjudge | xargs -r chmod +x'
sudo chmod +x ./domjudge/configure ./domjudge/etc/gen_all_secrets
```

### 2) 启动数据库与 DOMjudge（首次会自动初始化与构建 chroot）

```bash
docker compose up -d mariadb domjudge
docker compose logs -f domjudge   # 直至看到 nginx/php/judgedaemon RUNNING
```

DOMjudge 初始管理员密码：

```bash
docker compose exec domjudge cat /opt/domjudge/etc/initial_admin_password.secret
```

访问 DOMjudge：`http://<服务器IP>:12345`

### 3) 配置 XCPC-TOOLS 凭据

编辑 `./xcpc-tools/config.yaml` 填写 DOMjudge 的后台账户：

```yaml
type: domjudge
server: http://domjudge
username: admin
password: "<initial_admin_password>"
```

### 4) 启动 XCPC-TOOLS（已准备好 config.yaml）

```bash
docker compose up -d xcpc-tools
docker compose logs -f xcpc-tools
```

访问 XCPC-TOOLS：`http://<服务器IP>:5283`，默认账号：`admin / <viewPass>`。

### 5) 常见问题

- 端口不可达：检查 `docker compose ps` 是否存在 `0.0.0.0:12345->80/tcp` 与 `0.0.0.0:5283->5283/tcp`，并放行防火墙/安全组。
- DOMjudge 初始化缓慢：日志停在 `debootstrap` 下载属正常，已配置国内镜像；也可容器内执行 `dj_make_chroot -y -m <镜像>` 加速。
- 权限问题：确保宿主目录属主为 `1000:1000` 且关键脚本具备执行位；如从 Windows 拷贝，可使用 `dos2unix` 纠正换行。

---

## 批量部署选手机 Monitor（Linux，pssh）

前提：控制端可免密 SSH 登录所有选手机（或使用同一密码，并在命令中改用 `-A` 交互）。服务端地址为 `http://<SERVER>:5283`。

1) 安装 parallel-ssh

```bash
sudo apt-get update && sudo apt-get install -y pssh
```

2) 准备 IP 列表（每行一个）

```bash
cat > ips.txt <<'EOF'
10.0.0.101
10.0.0.102
# ...
EOF
```

3) 设置变量（把 SERVER 换成你的服务端 IP/域名）

```bash
SERVER=10.0.0.1
REPORT="http://${SERVER}:5283/report"
USER=root
OPTS="-O StrictHostKeyChecking=no"
```

4) 保障依赖（目标机安装 curl）

```bash
pssh -h ips.txt -l $USER $OPTS "which curl >/dev/null 2>&1 || (sudo apt-get update -y && sudo apt-get install -y curl)"
```

5) 分发监控脚本并安装为可执行

```bash
pscp -h ips.txt -l $USER $OPTS xcpc-tools-main/scripts/monitor /tmp/monitor
pssh -h ips.txt -l $USER $OPTS "sudo install -m 0755 /tmp/monitor /usr/local/bin/xcpc-monitor"
```

6) 下发 systemd 定时器（每 30s 上报一次）并启用

```bash
pssh -h ips.txt -l $USER $OPTS "sudo bash -lc '
cat >/etc/systemd/system/xcpc-monitor.service <<EOF
[Unit]
Description=XCPC Monitor heartbeat
[Service]
Type=oneshot
Environment=HEARTBEATURL=${REPORT}
ExecStart=/usr/local/bin/xcpc-monitor
EOF

cat >/etc/systemd/system/xcpc-monitor.timer <<EOF
[Unit]
Description=XCPC Monitor heartbeat timer
[Timer]
OnBootSec=10s
OnUnitActiveSec=30s
AccuracySec=1s
Unit=xcpc-monitor.service
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now xcpc-monitor.timer
'"
```

7) 验证

```bash
pssh -h ips.txt -l $USER $OPTS "systemctl is-active xcpc-monitor.timer && echo OK"
# 服务端 UI 的 Monitor 会陆续出现机器；离线超过 2 分钟会进入 #ErrMachine 分组
```

卸载（可选）

```bash
pssh -h ips.txt -l $USER $OPTS "sudo systemctl disable --now xcpc-monitor.timer; sudo rm -f /etc/systemd/system/xcpc-monitor.* /usr/local/bin/xcpc-monitor; sudo systemctl daemon-reload"
```

