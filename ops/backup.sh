#!/bin/bash
# WeKnora 备份脚本：导出数据库（逻辑备份）+ 文件卷 + 配置与密钥
# 用法: ./ops/backup.sh [备份目录名]
# 备份位置: ~/weknora-backups/<名字>（默认按时间戳，保留最近 10 份）
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# ---- 从 .env 读取配置 ----
if [ ! -f .env ]; then
  echo "[ERROR] .env 不存在，请先从 .env.example 复制并配置" >&2
  exit 1
fi
set -a; . ./.env; set +a

BACKUP_ROOT="${WEKNORA_BACKUP_ROOT:-$HOME/weknora-backups}"
TS="$(date +%Y%m%d-%H%M%S)"
NAME="${1:-weknora-$TS}"
DEST="$BACKUP_ROOT/$NAME"
PROJECT="weknora"  # compose 项目名 = 目录名小写

mkdir -p "$DEST"

echo "==> 备份到 $DEST"

# ---- 1. 数据库逻辑备份（pg_dump 自定义格式，可跨版本恢复）----
echo "==> [1/4] PostgreSQL pg_dump ..."
docker compose exec -T postgres pg_dump -U "${DB_USER:-postgres}" -Fc "${DB_NAME:-WeKnora}" > "$DEST/database.dump"

# ---- 2. 文件存储卷（data-files: 上传的原始文件/解析产物）----
echo "==> [2/4] data-files 卷打包 ..."
docker run --rm \
  -v "${PROJECT}_data-files:/src:ro" \
  -v "$DEST:/dst" \
  alpine:3 tar -czf /dst/data-files.tgz -C /src .

# ---- 3. 配置与密钥（.env + config/）----
echo "==> [3/4] .env 与 config/ 打包（含 SYSTEM_AES_KEY，务必妥善保管）..."
tar -czf "$DEST/config.tgz" -C "$REPO" .env config/

# ---- 4. 清单 ----
echo "==> [4/4] 生成清单 ..."
{
  echo "created_at: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "weknora_version: $(cat VERSION 2>/dev/null || unknown)"
  echo "git_commit: $(git rev-parse --short HEAD 2>/dev/null || unknown)"
  echo "compose_services: $(docker compose ps --services --filter status=running 2>/dev/null | tr '\n' ' ')"
  echo "restore: ./ops/restore.sh $DEST"
} > "$DEST/MANIFEST.txt"

# ---- 保留最近 10 份 ----
ls -1dt "$BACKUP_ROOT"/*/ 2>/dev/null | tail -n +11 | xargs -r rm -rf

echo ""
echo "[OK] 备份完成: $DEST"
du -sh "$DEST"
echo "恢复方法: ./ops/restore.sh $DEST"
echo "注意: .env 中的 SYSTEM_AES_KEY/JWT_SECRET 必须与数据库一同迁移，否则加密字段无法解密。"
