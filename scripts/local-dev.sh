#!/usr/bin/env bash
# GEOFlow 本机开发一键启动（非 Docker）
# 用法: bash scripts/local-dev.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PHP_BIN="${PHP_BIN:-}"
if [[ -z "$PHP_BIN" ]]; then
  if command -v php8.4 >/dev/null 2>&1; then
    PHP_BIN=php8.4
  elif php -r 'exit(version_compare(PHP_VERSION, "8.4.0", ">=") ? 0 : 1);' 2>/dev/null; then
    PHP_BIN=php
  else
    echo "错误: 需要 PHP 8.4+（composer.lock 依赖 Symfony 8）。"
    echo "  macOS: brew install php@8.4  或 使用 Docker: docker compose up -d"
    exit 1
  fi
fi

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "已创建 .env，请确认 DB_* 与 REDIS_* 指向本机。"
fi

# 本机运行时把 Docker 服务名改回 127.0.0.1
if grep -q '^DB_HOST=postgres' .env 2>/dev/null; then
  sed -i.bak 's/^DB_HOST=postgres/DB_HOST=127.0.0.1/' .env && rm -f .env.bak
fi
if grep -q '^REDIS_HOST=redis' .env 2>/dev/null; then
  sed -i.bak 's/^REDIS_HOST=redis/REDIS_HOST=127.0.0.1/' .env && rm -f .env.bak
fi
if grep -q '^APP_URL=http://localhost:18080' .env 2>/dev/null; then
  sed -i.bak 's|^APP_URL=http://localhost:18080|APP_URL=http://127.0.0.1:8080|' .env && rm -f .env.bak
fi

if ! grep -q '^APP_KEY=base64:' .env 2>/dev/null; then
  "$PHP_BIN" artisan key:generate --force
fi

chmod -R ug+rwx storage bootstrap/cache 2>/dev/null || true
"$PHP_BIN" artisan storage:link 2>/dev/null || true
"$PHP_BIN" artisan migrate --force

if ! "$PHP_BIN" artisan tinker --execute="echo \\App\\Models\\Admin::query()->exists() ? '1' : '0';" 2>/dev/null | grep -q 1; then
  "$PHP_BIN" artisan db:seed --force
fi

PORT="${APP_SERVE_PORT:-8080}"
HOST="${APP_SERVE_HOST:-0.0.0.0}"

echo ""
echo "=========================================="
echo " GEOFlow 本机开发服务"
echo "=========================================="
echo " 前台: http://127.0.0.1:${PORT}/"
echo " 后台: http://127.0.0.1:${PORT}/geo_admin/login"
echo " 账号: admin / password"
echo ""
echo " Docker 部署请用端口 18080: http://localhost:18080"
echo " 另开终端运行队列与调度:"
echo "   $PHP_BIN artisan queue:work redis --queue=geoflow,distribution,default --timeout=300"
echo "   $PHP_BIN artisan schedule:work"
echo "=========================================="
echo ""

exec "$PHP_BIN" artisan serve --host="$HOST" --port="$PORT"
