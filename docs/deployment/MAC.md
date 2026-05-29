# macOS 本机部署指南

在 **你自己的 Mac 终端**（不是 Cursor 云端）中执行以下步骤。

## 一键部署（推荐）

```bash
cd ~/path/to/GEOFlow    # 进入你 clone 的仓库目录
git pull                # 拉取含 mac-deploy.sh 的最新代码
bash scripts/mac-deploy.sh
```

脚本会自动：

1. 用 Homebrew 安装 PHP 8.4、PostgreSQL 16、Redis、Composer
2. 创建数据库 `geo_flow` 与用户 `geo_user`
3. 配置 `.env` 指向本机 `127.0.0.1`
4. 执行 `composer install`、迁移、种子数据
5. 在后台启动 Web（默认 **8888**）、队列、调度器
6. 自动用浏览器打开后台登录页

**访问地址：**

- 前台：http://127.0.0.1:8888/
- 后台：http://127.0.0.1:8888/geo_admin/login
- 账号：`admin` / 密码：`password`

**停止服务：**

```bash
bash scripts/mac-deploy.sh --stop
```

**换端口：**

```bash
APP_SERVE_PORT=8090 bash scripts/mac-deploy.sh
```

## 使用 Docker（仅需 Docker Desktop）

```bash
bash scripts/mac-deploy.sh --docker
```

访问：http://127.0.0.1:18080/geo_admin/login

## 前置要求

- macOS 12+
- [Homebrew](https://brew.sh/)（原生部署）
- 或 [Docker Desktop](https://www.docker.com/products/docker-desktop/)（`--docker`）

## 常见问题

| 问题 | 处理 |
|------|------|
| `127.0.0.1:8888` 连接被拒绝 | 在 **Mac 终端** 运行 `bash scripts/mac-deploy.sh`，不要在 Cursor 云端里用浏览器访问本机地址 |
| PHP 版本不够 | `brew install php@8.4` 后 `export PATH="$(brew --prefix php@8.4)/bin:$PATH"` |
| PostgreSQL 连不上 | `brew services restart postgresql@16` |
| Redis 连不上 | `brew services start redis` |
| pgvector 报错 | `brew install pgvector` 后重新执行部署脚本 |

## 与 Cursor 云端的区别

| 环境 | 访问方式 |
|------|----------|
| **Mac 本机**（本指南） | http://127.0.0.1:8888 — 服务跑在你电脑上 |
| **Cursor 云端 Agent** | 必须用 Ports 转发或隧道，Mac 上的 127.0.0.1 连不到云端 |
