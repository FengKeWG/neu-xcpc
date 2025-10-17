## 启动前权限准备
首次启动或更换宿主挂载目录时，建议先在宿主机执行以下命令，避免容器内执行脚本出现 Permission denied：

```bash
# 1) 目录属主改为容器内用户 uid/gid=1000（DOMjudge 镜像内默认）
sudo chown -R 1000:1000 /mnt/data/domjudge

# 2) 目录与关键脚本赋予执行权限
sudo chmod 755 /mnt/data/domjudge
sudo chmod +x /mnt/data/domjudge/configure

# 3) 批量为所有以 shebang 开头的脚本加执行位（etc、judge、misc-tools 等都会覆盖）
sudo bash -lc 'grep -rIl "^#!" /mnt/data/domjudge | xargs -r chmod +x'

# 4) 检查挂载是否包含 noexec；若包含需移除 noexec 或迁移目录
findmnt -no OPTIONS /mnt/data
# 若输出含 noexec，可尝试：
# sudo mount -o remount,exec /mnt/data
# 无法修改时，建议迁移到本地 ext4 路径，例如：
# sudo rsync -aHAX /mnt/data/domjudge/ /opt/domjudge-src/
# sudo chown -R 1000:1000 /opt/domjudge-src
# 然后将 compose 的挂载改为：/opt/domjudge-src:/opt/domjudge
```

准备完成后再执行：

```bash
docker compose pull
docker compose up -d
```

