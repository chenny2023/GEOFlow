#!/usr/bin/env bash
# GEOFlow — macOS 本机一键部署（Homebrew 原生栈 或 Docker）
#
# 用法:
#   bash scripts/mac-deploy.sh           # 本机 PHP + Postgres + Redis（推荐）
#   bash scripts/mac-deploy.sh --docker  # 仅需 Docker Desktop
#   bash scripts/mac-deploy.sh --stop    # 停止本脚本启动的后台进程
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PORT="${APP_SERVE_PORT:-8888}"
PID_FILE="$ROOT/storage/app/mac-deploy.pids"
LOG_DIR="$ROOT/storage/logs/mac-deploy"

log() { echo "[mac-deploy] $*"; }
die() { echo "[mac-deploy] 错误: $*" >&2; exit 1; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  die "此脚本仅用于 macOS。Linux 请用: bash scripts/local-dev.sh"
fi

# macOS sed
sed_inplace() {
  if sed --version >/dev/null 2>&1; then
    sed -i "$@"
  else
    local expr=$1; shift
    sed -i '' "$expr" "$@"
  fi
}

ensure_env_local() {
  [[ -f .env ]] || cp .env.example .env
  sed_inplace 's/^DB_HOST=postgres/DB_HOST=127.0.0.1/' .env
  sed_inplace 's/^REDIS_HOST=redis/REDIS_HOST=127.0.0.1/' .env
  sed_inplace 's/^REVERB_BROADCAST_HOST=reverb/REVERB_BROADCAST_HOST=127.0.0.1/' .env
  sed_inplace "s|^APP_URL=.*|APP_URL=http://127.0.0.1:${PORT}|" .env
  sed_inplace 's/^APP_ENV=production/APP_ENV=local/' .env
  sed_inplace 's/^APP_DEBUG=false/APP_DEBUG=true/' .env
}

find_php() {
  if [[ -n "${PHP_BIN:-}" ]] && command -v "$PHP_BIN" >/dev/null 2>&1; then
    echo "$PHP_BIN"
    return
  fi
  for candidate in \
    "$(brew --prefix php@8.4 2>/dev/null)/bin/php" \
    /opt/homebrew/opt/php@8.4/bin/php \
    /usr/local/opt/php@8.4/bin/php \
    php8.4 php; do
    if [[ -x "$candidate" ]] || command -v "$candidate" >/dev/null 2>&1; then
      if "$candidate" -r 'exit(version_compare(PHP_VERSION, "8.4.0", ">=") ? 0 : 1);' 2>/dev/null; then
        echo "$candidate"
        return
      fi
    fi
  done
  return 1
}

stop_background() {
  if [[ -f "$PID_FILE" ]]; then
    log "停止后台进程..."
    while read -r pid name; do
      [[ -n "$pid" ]] && kill "$pid" 2>/dev/null && log "  已停止 $name (pid $pid)" || true
    done < "$PID_FILE"
    rm -f "$PID_FILE"
  fi
}

start_background() {
  local php="$1"
  mkdir -p "$LOG_DIR"
  stop_background
  : > "$PID_FILE"

  nohup "$php" artisan serve --host=127.0.0.1 --port="$PORT" >>"$LOG_DIR/web.log" 2>&1 &
  echo "$! web" >> "$PID_FILE"
  nohup "$php" artisan queue:work redis --queue=geoflow,distribution,default --sleep=1 --tries=1 --timeout=300 >>"$LOG_DIR/queue.log" 2>&1 &
  echo "$! queue" >> "$PID_FILE"
  nohup "$php" artisan schedule:work >>"$LOG_DIR/scheduler.log" 2>&1 &
  echo "$! scheduler" >> "$PID_FILE"
}

wait_http() {
  local i
  for i in $(seq 1 30); do
    if curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 1 "http://127.0.0.1:${PORT}/" 2>/dev/null | grep -q 200; then
      return 0
    fi
    sleep 1
  done
  return 1
}

install_brew_deps() {
  if ! command -v brew >/dev/null 2>&1; then
    die "未安装 Homebrew。请先执行:\n  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
  fi

  log "安装/检查 Homebrew 依赖（首次可能需几分钟）..."
  brew update
  brew install php@8.4 composer postgresql@16 redis
  brew install pgvector 2>/dev/null || log "提示: 若 RAG 向量检索失败，可稍后执行 brew install pgvector"

  brew services start postgresql@16
  brew services start redis

  export PATH="$(brew --prefix php@8.4)/bin:$(brew --prefix php@8.4)/sbin:${PATH:-}"

  if ! php -m 2>/dev/null | grep -qi redis; then
    log "安装 PHP redis 扩展..."
    pecl install redis <<< "" 2>/dev/null || true
    echo "extension=redis.so" >> "$(brew --prefix php@8.4)/etc/php/8.4/conf.d/ext-redis.ini" 2>/dev/null || true
  fi
}

setup_postgres() {
  export PATH="$(brew --prefix postgresql@16)/bin:${PATH:-}"
  local psql=(psql postgres)

  if ! "${psql[@]}" -c "SELECT 1" >/dev/null 2>&1; then
    die "无法连接 PostgreSQL。请执行: brew services restart postgresql@16"
  fi

  log "初始化数据库 geo_flow ..."
  "${psql[@]}" -v ON_ERROR_STOP=1 <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'geo_user') THEN
    CREATE USER geo_user WITH PASSWORD 'geo_password' CREATEDB LOGIN;
  END IF;
END
$$;
SELECT 'CREATE DATABASE geo_flow OWNER geo_user'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'geo_flow')\gexec
GRANT ALL PRIVILEGES ON DATABASE geo_flow TO geo_user;
SQL

  psql -h 127.0.0.1 -U geo_user -d geo_flow -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>/dev/null \
    || psql postgres -d geo_flow -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>/dev/null \
    || log "警告: pgvector 扩展未安装，知识库向量检索可能不可用。请: brew install pgvector"
}

deploy_native() {
  install_brew_deps
  setup_postgres

  PHP="$(find_php)" || die "未找到 PHP 8.4。请执行: brew install php@8.4"
  log "使用 PHP: $($PHP -v | head -1)"

  command -v composer >/dev/null 2>&1 || die "未找到 composer"

  ensure_env_local
  chmod -R ug+rwx storage bootstrap/cache 2>/dev/null || true

  log "安装 Composer 依赖..."
  composer install --no-interaction --prefer-dist

  if ! grep -q '^APP_KEY=base64:' .env 2>/dev/null; then
    "$PHP" artisan key:generate --force
  fi

  "$PHP" artisan storage:link 2>/dev/null || true
  log "执行数据库迁移..."
  "$PHP" artisan migrate --force

  if ! "$PHP" artisan tinker --execute="echo \\App\\Models\\Admin::query()->exists() ? '1' : '0';" 2>/dev/null | grep -q 1; then
    "$PHP" artisan db:seed --force
  fi

  start_background "$PHP"

  if wait_http; then
    print_success
  else
    log "服务启动超时，请查看日志: $LOG_DIR/web.log"
    tail -20 "$LOG_DIR/web.log" 2>/dev/null || true
    die "Web 未在端口 ${PORT} 响应"
  fi
}

deploy_docker() {
  command -v docker >/dev/null 2>&1 || die "未安装 Docker Desktop: https://www.docker.com/products/docker-desktop/"
  docker info >/dev/null 2>&1 || die "Docker 未运行，请先打开 Docker Desktop"

  [[ -f .env ]] || cp .env.example .env
  sed_inplace 's|^APP_URL=.*|APP_URL=http://127.0.0.1:18080|' .env

  log "使用 Docker Compose 构建并启动..."
  docker compose build
  docker compose up -d

  local i
  for i in $(seq 1 60); do
    if curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 2 http://127.0.0.1:18080/ 2>/dev/null | grep -q 200; then
      PORT=18080
      print_success
      return
    fi
    sleep 2
  done
  die "Docker 启动超时。请执行: docker compose logs -f app"
}

print_success() {
  echo ""
  echo "=============================================="
  echo " GEOFlow 已在你的 Mac 上部署完成"
  echo "=============================================="
  echo " 前台: http://127.0.0.1:${PORT}/"
  echo " 后台: http://127.0.0.1:${PORT}/geo_admin/login"
  echo " 账号: admin"
  echo " 密码: password"
  echo ""
  if [[ "${1:-}" != "docker" ]]; then
    echo " 后台进程 PID 记录在: storage/app/mac-deploy.pids"
    echo " 日志目录: storage/logs/mac-deploy/"
    echo " 停止服务: bash scripts/mac-deploy.sh --stop"
  else
    echo " 停止 Docker: docker compose down"
  fi
  echo "=============================================="
  echo ""
  if command -v open >/dev/null 2>&1; then
    open "http://127.0.0.1:${PORT}/geo_admin/login" 2>/dev/null || true
  fi
}

case "${1:-}" in
  --stop)
    stop_background
    log "已停止"
    exit 0
    ;;
  --docker)
    deploy_docker
    ;;
  --help|-h)
    echo "用法: bash scripts/mac-deploy.sh [--docker|--stop|--help]"
    exit 0
    ;;
  "")
    deploy_native
    ;;
  *)
    die "未知参数: $1（可用 --docker / --stop）"
    ;;
esac
