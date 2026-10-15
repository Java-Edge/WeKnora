#!/bin/bash
# WeKnora 恢复脚本：从备份目录恢复（数据库 + 文件卷 + 可选配置/密钥）
# 用法:
#   ./ops/restore.sh <备份目录>           迁移到本机（保留本机 .env，需密钥一致）
#   ./ops/restore.sh <备份目录> --with-env 用备份中的 .env 覆盖本机（全新机器迁移用）
# 警告: 该操作会清空当前 WeKnora 的数据库与文件卷，请先备份当前数据。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

BACKUP="${1:?用法: ./ops/restore.sh <备份目录> [--with-env]}"
WITH_ENV=0
[ "${2:-}" = "--with-env" ] && WITH_ENV=1

[ -d "$BACKUP" ] || { echo "[ERROR] 备份目录不存在: $BACKUP" >&2; exit 1; }
[ -f "$BACKUP/database.dump" ] || { echo "[ERROR] 缺少 database.dump" >&2; exit 1; }

if [ ! -f .env ]; then
  echo "[ERROR] .env 不存在，请先从 .env.example 配置（或使用 --with-env 从备份恢复）" >&2
  exit 1
fi
set -a; . ./.env; set +a
PROJECT="weknora"

echo "!!! 即将用备份覆盖当前数据:"
echo "    备份: $BACKUP"
cat "$BACKUP/MANIFEST.txt" 2>/dev/null || true
echo "    目标: $REPO (project=$PROJECT)"
read -r -p "确认继续? 输入 yes: " ans
[ "$ans" = "yes" ] || { echo "已取消"; exit 1; }

# ---- 1. 停止并清空数据卷 ----
echo "==> 停止服务并删除数据卷 ..."
docker compose down
docker volume rm "${PROJECT}_postgres-data" "${PROJECT}_data-files" >/dev/null 2>&1 || true

# ---- 2. 先用空卷启动 postgres ----
echo "==> 启动新数据库 ..."
docker compose up -d postgres redis
for i in $(seq 1 30); do
  docker compose exec -T postgres pg_isready -U "${DB_USER:-postgres}" -d "${DB_NAME:-WeKnora}" >/dev/null 2>&1 && break
  sleep 2
done

# ---- 3. 恢复数据库 ----
echo "==> pg_restore ..."
cat "$BACKUP/database.dump" | docker compose exec -T postgres pg_restore -U "${DB_USER:-postgres}" -d "${DB_NAME:-WeKnora}" --no-owner --clean --if-exists || {
  echo "[WARN] pg_restore 报告了非零退出码，部分告警可忽略，请检查日志"
}

# ---- 4. 恢复文件卷 ----
if [ -f "$BACKUP/data-files.tgz" ]; then
  echo "==> 恢复 data-files 卷 ..."
  docker run --rm \
    -v "${PROJECT}_data-files:/dst" \
    -v "$BACKUP:/src:ro" \
    alpine:3 sh -c "rm -rf /dst/.??* /dst/* 2>/dev/null; tar -xzf /src/data-files.tgz -C /dst"
fi

# ---- 5. 恢复配置与密钥（可选）----
if [ "$WITH_ENV" = "1" ]; then
  echo "==> 用备份中的 .env 与 config/ 覆盖本机 ..."
  tar -xzf "$BACKUP/config.tgz" -C "$REPO"
elif [ -f "$BACKUP/config.tgz" ]; then
  echo "==> 保留本机 .env（注意: 数据库中的加密字段需要与备份时一致的 SYSTEM_AES_KEY）"
  tar -xzf "$BACKUP/config.tgz" -C "$REPO" --exclude=.env 2>/dev/null || true
fi

# ---- 6. 全栈启动 ----
echo "==> 启动全部服务 ..."
docker compose up -d

FP="${FRONTEND_PORT:-18090}"
AP="${APP_PORT:-18091}"
for i in $(seq 1 40); do
  code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$FP/" 2>/dev/null || true)
  [ "$code" = "200" ] || [ "$code" = "302" ] || [ "$code" = "301" ] && break
  sleep 3
done
echo ""
echo "[DONE] 恢复完成: http://127.0.0.1:$FP/ (API: http://127.0.0.1:$AP/health)"
