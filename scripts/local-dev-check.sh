#!/usr/bin/env bash
# GEOFlow 本机环境诊断
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ok() { echo "  [OK] $*"; }
fail() { echo "  [FAIL] $*"; }

echo "=== GEOFlow 本地环境检查 ==="
echo ""

PHP_BIN="${PHP_BIN:-php8.4}"
command -v "$PHP_BIN" >/dev/null 2>&1 || PHP_BIN=php
if command -v "$PHP_BIN" >/dev/null 2>&1; then
  ok "PHP: $($PHP_BIN -v | head -1)"
else
  fail "未找到 PHP 8.4"
fi

[[ -f .env ]] && ok ".env 存在" || fail "缺少 .env（执行 cp .env.example .env）"

if [[ -f .env ]]; then
  grep -q '^APP_KEY=base64:' .env && ok "APP_KEY 已设置" || fail "APP_KEY 未设置（php artisan key:generate）"
  DB_HOST=$(grep '^DB_HOST=' .env | cut -d= -f2)
  REDIS_HOST=$(grep '^REDIS_HOST=' .env | cut -d= -f2)
  APP_URL=$(grep '^APP_URL=' .env | cut -d= -f2)
  echo "  DB_HOST=$DB_HOST  REDIS_HOST=$REDIS_HOST  APP_URL=$APP_URL"
  [[ "$DB_HOST" == "postgres" || "$DB_HOST" == "redis" ]] && fail "DB/Redis 仍为 Docker 主机名，本机请改为 127.0.0.1 或使用 docker compose"
fi

command -v redis-cli >/dev/null 2>&1 && redis-cli ping >/dev/null 2>&1 && ok "Redis 可连接" || fail "Redis 未运行（brew services start redis）"

if command -v psql >/dev/null 2>&1; then
  psql -h 127.0.0.1 -U geo_user -d geo_flow -c 'SELECT 1' >/dev/null 2>&1 && ok "PostgreSQL geo_flow 可连接" || fail "PostgreSQL 不可连接（检查库与用户）"
else
  echo "  [SKIP] 未安装 psql，跳过数据库检查"
fi

for port in 8888 8080 18080; do
  if curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 2 "http://127.0.0.1:${port}/" 2>/dev/null | grep -q 200; then
    ok "HTTP ${port} 返回 200 — http://127.0.0.1:${port}/"
  else
    echo "  [--] 端口 ${port} 无响应"
  fi
done

echo ""
echo "常见访问地址:"
echo "  本机 PHP:  http://127.0.0.1:8888/geo_admin/login (默认)"
echo "  备用端口:  http://127.0.0.1:8080/geo_admin/login"
echo "  Docker:    http://127.0.0.1:18080/geo_admin/login"
