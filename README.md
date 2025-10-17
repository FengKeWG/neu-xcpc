## 一键部署：DOMjudge + MariaDB + XCPC-TOOLS

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

