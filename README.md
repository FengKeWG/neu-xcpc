## 一键部署：DOMjudge + MariaDB + XCPC-TOOLS

### 1) 准备宿主目录与权限（仅首次）

```bash
sudo mkdir -p /mnt/data/domjudge /mnt/data/domjudge-db /mnt/data/xcpc-tools
sudo chown -R 1000:1000 /mnt/data/domjudge /mnt/data/domjudge-db /mnt/data/xcpc-tools
sudo chmod 755 /mnt/data/domjudge /mnt/data/xcpc-tools
sudo chmod +x /mnt/data/xcpc-tools/xcpc-tools
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

### 3) 生成 DOMjudge API Token

1) 使用初始管理员登录 DOMjudge 后台。
2) 右上角用户名 → API tokens → Create new token → 复制生成的 Token（只显示一次）。
3) 编辑宿主机的 `/mnt/data/xcpc-tools/config.yaml`，填写：

```yaml
type: domjudge
server: http://domjudge
token: "<上一步复制的token>"
# 使用 token 时可删除 username/password 字段
```

提示：如不使用 token，也可保留 `username/password`（例如管理员账户与初始密码）。

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

