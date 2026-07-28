#!/usr/bin/env bash
#
# rollback.sh — site-deploy skill 手動回滾腳本(Phase 6)
#
# 用法:
#   scripts/rollback.sh          # 只列出可用 releases(含 .deploy-meta 資訊)
#   scripts/rollback.sh <TS>     # 回滾到指定 release(TS = YYYYmmddHHMMSS)
#
# 硬性約定(SKILL-SPEC.md §8):
#   - 一律從專案根目錄執行;參數來自 deploy/deploy.conf
#   - 遠端 compose 呼叫固定:docker compose -f compose.yml -f compose.prod.yml
#   - symlink 切換固定:cd /srv/$SITE && ln -s "releases/$TS" current.tmp && mv -T current.tmp current
#
# smoke-test.sh remote 的 exit code 約定:
#   0 = 通過;2 = 憑證/TLS 可等待型失敗;其餘非零 = 應用層失敗

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 讀取設定(必須從專案根執行) ----------
if [ ! -f deploy/deploy.conf ]; then
  echo "[中止] 找不到 deploy/deploy.conf,請從專案根目錄執行本腳本。" >&2
  exit 1
fi
# shellcheck source=/dev/null
source deploy/deploy.conf

: "${SITE:?deploy.conf 缺少 SITE}"
: "${DOMAIN:?deploy.conf 缺少 DOMAIN}"
: "${SSH_HOST:?deploy.conf 缺少 SSH_HOST}"
: "${STACK:?deploy.conf 缺少 STACK}"

case "$STACK" in
  php|ci4|laravel|node) ;;
  *)
    echo "[中止] STACK 值不合法:$STACK(允許:php|ci4|laravel|node)" >&2
    exit 1
    ;;
esac

# 遠端 compose 固定呼叫式(硬性)
COMPOSE_REMOTE="docker compose -f compose.yml -f compose.prod.yml"

TARGET="${1:-}"

# ---------- 1. 列出 releases(含各自 .deploy-meta,標記 current 指向者) ----------
echo "==> 遠端 releases 一覽(* = current 目前指向):"
ssh "$SSH_HOST" bash -s -- "$SITE" <<'REMOTE'
set -eu
SITE="$1"
BASE="/srv/$SITE"
CUR="$(readlink "$BASE/current" 2>/dev/null || true)"
found=0
for d in "$BASE"/releases/*/; do
  [ -d "$d" ] || continue
  found=1
  ts="$(basename "$d")"
  sha=""; branch=""; deployed_at=""; host=""
  if [ -f "$d/.deploy-meta" ]; then
    while IFS='=' read -r k v; do
      case "$k" in
        sha) sha="$v" ;;
        branch) branch="$v" ;;
        deployed_at) deployed_at="$v" ;;
        host) host="$v" ;;
      esac
    done < "$d/.deploy-meta"
  fi
  mark=" "
  if [ "releases/$ts" = "$CUR" ]; then
    mark="*"
  fi
  printf '%s %s  sha=%s  branch=%s  deployed_at=%s  host=%s\n' \
    "$mark" "$ts" "${sha:-?}" "${branch:-?}" "${deployed_at:-?}" "${host:-?}"
done
if [ "$found" -eq 0 ]; then
  echo "(無任何 release)"
fi
REMOTE

# ---------- 2. 無參數:列完清單即退出,提示用法 ----------
if [ -z "$TARGET" ]; then
  echo ""
  echo "用法:scripts/rollback.sh <TS>"
  echo "請從上方清單選定目標 release 的 TS 後重新執行。"
  exit 0
fi

if ! [[ "$TARGET" =~ ^[0-9]+$ ]]; then
  echo "[中止] TS 格式不正確(應為純數字時間戳,如 20260728120000):$TARGET" >&2
  exit 1
fi

if ! ssh "$SSH_HOST" "test -d \"/srv/$SITE/releases/$TARGET\""; then
  echo "[中止] 目標 release 不存在:/srv/$SITE/releases/$TARGET" >&2
  exit 1
fi

# ---------- 3. 原子切換 → 重啟 → smoke test ----------
echo "==> 原子切換 current -> releases/$TARGET"
# 相對目標 + 原子切換(容器內才解析得到;mv -T 消除非原子窗口)
ssh "$SSH_HOST" "cd /srv/$SITE && ln -sfn \"releases/$TARGET\" current.tmp && mv -T current.tmp current"

echo "==> 啟動/重啟服務"
ssh "$SSH_HOST" "cd /srv/$SITE/current && $COMPOSE_REMOTE up -d"
case "$STACK" in
  php|ci4|laravel)
    # realpath cache 對策:php 系換版後 reload php-fpm 為必要步驟,不可省略
    ssh "$SSH_HOST" "cd /srv/$SITE/current && $COMPOSE_REMOTE exec -T app reload-php"
    echo "    已 reload php-fpm"
    ;;
  node)
    # node 換版必重啟容器
    ssh "$SSH_HOST" "cd /srv/$SITE/current && $COMPOSE_REMOTE restart app"
    echo "    已重啟 app 容器"
    ;;
esac

# 啟用了 queue worker 的站:換版後必須重啟,否則 worker 繼續跑舊 release 程式碼
if ssh "$SSH_HOST" "cd /srv/$SITE/current && $COMPOSE_REMOTE ps --services | grep -qx worker"; then
  ssh "$SSH_HOST" "cd /srv/$SITE/current && $COMPOSE_REMOTE restart worker"
  echo "    已重啟 queue worker"
fi

echo "==> 遠端 smoke test"
set +e
"$SCRIPT_DIR/smoke-test.sh" remote
SMOKE_RC=$?
set -e

# ---------- 4. 結尾提醒(不論成敗都提醒) ----------
echo ""
echo "[提醒] DB migration 不會自動回滾;涉及 schema 的回退,請人工確認資料庫狀態後再決定後續處置。"

if [ "$SMOKE_RC" -ne 0 ]; then
  echo "[失敗] 回滾後 remote smoke test 未通過(exit code $SMOKE_RC)。" >&2
  if [ "$SMOKE_RC" -eq 2 ]; then
    echo "       屬憑證/TLS 類失敗:看 Caddy log(ssh $SSH_HOST 'cd /srv/$SITE/current && $COMPOSE_REMOTE logs caddy')" >&2
    echo "       並檢查 DNS:dig +short $DOMAIN;dig +short www.$DOMAIN" >&2
  fi
  exit 1
fi

echo "[完成] 已回滾至 releases/$TARGET,remote smoke test 通過。"
