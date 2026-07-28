#!/usr/bin/env bash
#
# deploy.sh — site-deploy skill 部署腳本(Phase 4:首次與日常共用同一套流程)
#
# 用法:
#   scripts/deploy.sh                    # 一般部署
#   scripts/deploy.sh --force-divergent  # 多機防護檢查失敗時,經互動確認後強制部署
#
# 硬性約定(SKILL-SPEC.md §8):
#   - 一律從專案根目錄執行;參數來自 deploy/deploy.conf
#   - 遠端 compose 呼叫固定:docker compose -f compose.yml -f compose.prod.yml
#   - symlink 切換固定:cd /srv/$SITE && ln -s "releases/$TS" current.tmp && mv -T current.tmp current
#   - .deploy-meta 為 KEY=VALUE 行:sha、branch、deployed_at、host
#
# smoke-test.sh remote 的 exit code 約定:
#   0 = 通過;2 = 憑證/TLS 可等待型失敗(回滾無效,不觸發回滾);其餘非零 = 應用層失敗(觸發回滾)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 參數解析 ----------
FORCE_DIVERGENT=0
for arg in "$@"; do
  case "$arg" in
    --force-divergent)
      FORCE_DIVERGENT=1
      ;;
    *)
      echo "[中止] 未知參數:$arg" >&2
      echo "用法:scripts/deploy.sh [--force-divergent]" >&2
      exit 1
      ;;
  esac
done

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
KEEP_RELEASES="${KEEP_RELEASES:-5}"
WRITABLE_DIRS="${WRITABLE_DIRS:-}"

case "$STACK" in
  php|ci4|laravel|node) ;;
  *)
    echo "[中止] STACK 值不合法:$STACK(允許:php|ci4|laravel|node)" >&2
    exit 1
    ;;
esac

# 遠端 compose 固定呼叫式(硬性)
COMPOSE_REMOTE="docker compose -f compose.yml -f compose.prod.yml"

echo "==> 部署開始:site=$SITE domain=$DOMAIN stack=$STACK ssh=$SSH_HOST"

# ---------- [1/10] 前置檢查 ----------
echo "==> [1/10] 前置檢查"

# 1a. git working tree 必須 clean(部署內容必有版控)
if [ -n "$(git status --porcelain)" ]; then
  echo "[中止] git working tree 不乾淨,請先 commit 或 stash 後再部署。" >&2
  exit 1
fi
echo "    git working tree clean:通過"

# 1b. 本機 smoke test 必須全綠
echo "    執行本機 smoke test ..."
if ! "$SCRIPT_DIR/smoke-test.sh" local; then
  echo "[中止] 本機 smoke test 未通過,禁止部署。" >&2
  exit 1
fi
echo "    本機 smoke test:通過"

# 1c. 多機防護:遠端 current 的線上 SHA 必須是本機 HEAD 的祖先
#     (current/.deploy-meta 不存在 = 首次部署,跳過)
# 區分「檔案不存在(正當的首次部署)」與「ssh 連線失敗(exit 255)」——
# 連線失敗絕不能被靜默當成首次部署,否則多機防護會被繞過
set +e
REMOTE_META="$(ssh "$SSH_HOST" "cat /srv/$SITE/current/.deploy-meta 2>/dev/null")"
META_RC=$?
set -e
if [ "$META_RC" -eq 255 ]; then
  echo "[中止] SSH 連線失敗,無法讀取遠端 .deploy-meta;請確認連線正常後重試。" >&2
  exit 1
fi
if [ -z "$REMOTE_META" ]; then
  echo "    遠端無 current/.deploy-meta,視為首次部署,跳過多機防護。"
else
  REMOTE_SHA="$(printf '%s\n' "$REMOTE_META" | sed -n 's/^sha=//p' | head -n 1)"
  DIVERGED=0
  REASON=""
  if [ -z "$REMOTE_SHA" ]; then
    DIVERGED=1
    REASON="遠端 .deploy-meta 缺少 sha 欄位"
  elif ! git cat-file -e "$REMOTE_SHA" 2>/dev/null; then
    DIVERGED=1
    REASON="本機 git 沒有線上 SHA $REMOTE_SHA(git cat-file -e 失敗)"
  elif ! git merge-base --is-ancestor "$REMOTE_SHA" HEAD; then
    DIVERGED=1
    REASON="線上 SHA $REMOTE_SHA 不是本機 HEAD 的祖先"
  fi

  if [ "$DIVERGED" -eq 1 ]; then
    if [ "$FORCE_DIVERGENT" -ne 1 ]; then
      echo "[中止] 多機防護:$REASON。" >&2
      echo "       本機不含線上已部署版本,請先同步程式碼(git pull / fetch 共享 remote)再部署;" >&2
      echo "       確定要覆蓋線上版本,請加 --force-divergent 重跑。" >&2
      exit 1
    fi
    echo "[警告] 多機防護檢查失敗:$REASON"
    echo "[警告] 已指定 --force-divergent,將覆蓋線上版本(可能蓋掉他人部署的變更)。"
    read -r -p "確認強制部署請輸入 yes:" CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
      echo "[中止] 未輸入 yes,部署取消。" >&2
      exit 1
    fi
  else
    echo "    多機防護:線上 SHA 為本機 HEAD 祖先,通過"
  fi
fi

# ---------- [2/10] rsync 上傳 release + 寫入 .deploy-meta ----------
TS="$(date +%Y%m%d%H%M%S)"
SHA="$(git rev-parse HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
DEPLOYED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LOCAL_HOST="$(hostname)"
RELEASE_DIR="/srv/$SITE/releases/$TS"

echo "==> [2/10] 上傳 release:$RELEASE_DIR"
ssh "$SSH_HOST" "mkdir -p \"$RELEASE_DIR\""
# 排除樣式一律錨定(以 / 開頭 = 相對傳輸根),避免誤殺 app 內同名目錄(如 src/public/data);
# 依路徑約定,依賴與 build 產物只會出現在 src/ 下
rsync -az \
  --exclude /.env \
  --exclude /.git \
  --exclude /deploy/.env.production \
  --exclude /.ssh \
  --exclude '*.pem' \
  --exclude /data \
  --exclude /src/vendor \
  --exclude /src/node_modules \
  --exclude /src/.next \
  --exclude /src/dist \
  ./ "$SSH_HOST:$RELEASE_DIR/"

# .deploy-meta:KEY=VALUE 行,寫進 release
ssh "$SSH_HOST" "cat > \"$RELEASE_DIR/.deploy-meta\"" <<EOF
sha=$SHA
branch=$BRANCH
deployed_at=$DEPLOYED_AT
host=$LOCAL_HOST
EOF
echo "    上傳完成,.deploy-meta 已寫入(sha=$SHA)"

# ---------- [3/10] 需要時 build,啟動 postgres 並等 healthy ----------
echo "==> [3/10] 判斷是否需要 build image"
NEED_BUILD=0
if ! ssh "$SSH_HOST" "test -e /srv/$SITE/current"; then
  NEED_BUILD=1
  echo "    首次部署(遠端無 current),需要 build"
elif ! ssh "$SSH_HOST" "diff -rq \"/srv/$SITE/current/docker\" \"$RELEASE_DIR/docker\" >/dev/null 2>&1"; then
  NEED_BUILD=1
  echo "    docker/ 內容有變更,需要 build"
else
  echo "    docker/ 無變更,沿用既有 image"
fi

if [ "$NEED_BUILD" -eq 1 ]; then
  echo "    在遠端 build image ..."
  ssh "$SSH_HOST" "cd \"$RELEASE_DIR\" && $COMPOSE_REMOTE build"
fi

echo "    啟動 postgres 並等待 healthcheck(上限 60 秒)..."
ssh "$SSH_HOST" "cd \"$RELEASE_DIR\" && $COMPOSE_REMOTE up -d postgres"
# compose 專案名寫死 name: $SITE,容器名固定為 <site>-postgres-1
if ! ssh "$SSH_HOST" bash -s -- "$SITE" <<'REMOTE'
set -eu
SITE="$1"
status=""
for _ in $(seq 1 20); do
  status="$(docker inspect --format '{{.State.Health.Status}}' "${SITE}-postgres-1" 2>/dev/null || true)"
  if [ "$status" = "healthy" ]; then
    exit 0
  fi
  sleep 3
done
echo "postgres 未在 60 秒內達到 healthy(最後狀態:${status:-unknown})" >&2
exit 1
REMOTE
then
  echo "[中止] postgres healthcheck 逾時,部署中止。" >&2
  exit 1
fi
echo "    postgres healthy"

# ---------- [4/10] 依賴安裝(一次性容器,禁止 exec 依附運行中容器) ----------
echo "==> [4/10] 安裝依賴(一次性容器)"
case "$STACK" in
  php|ci4|laravel)
    if ssh "$SSH_HOST" "test -f \"$RELEASE_DIR/src/composer.json\""; then
      ssh "$SSH_HOST" "cd \"$RELEASE_DIR\" && $COMPOSE_REMOTE run --rm --no-deps -w \"$RELEASE_DIR/src\" app composer install --no-dev --no-interaction"
      echo "    composer install 完成"
    else
      echo "    src/composer.json 不存在,跳過 composer install。"
    fi
    ;;
  node)
    # npm ci 必須顯式 --include=dev(NODE_ENV=production 會靜默略過 devDependencies);
    # build 完成後才 prune 剝除 dev 依賴
    ssh "$SSH_HOST" "cd \"$RELEASE_DIR\" && $COMPOSE_REMOTE run --rm --no-deps -w \"$RELEASE_DIR/src\" app sh -c 'npm ci --include=dev && npm run build && npm prune --omit=dev'"
    echo "    npm ci + build + prune 完成"
    ;;
esac

# ---------- [5/10] 每-release 權限(WRITABLE_DIRS) ----------
echo "==> [5/10] 每-release 權限(WRITABLE_DIRS)"
if [ -n "$WRITABLE_DIRS" ]; then
  CHOWN_TARGETS=""
  for d in $WRITABLE_DIRS; do
    CHOWN_TARGETS="$CHOWN_TARGETS $RELEASE_DIR/$d"
  done
  ssh "$SSH_HOST" "cd \"$RELEASE_DIR\" && $COMPOSE_REMOTE run --rm -u root app chown -R www-data:www-data$CHOWN_TARGETS"
  echo "    已 chown www-data:www-data →$CHOWN_TARGETS"
else
  echo "    WRITABLE_DIRS 為空,跳過。"
fi

# ---------- [6/10] migration ----------
echo "==> [6/10] migration"
case "$STACK" in
  laravel)
    # 以 www-data 執行:migration 過程寫入 storage/log 時不會留下 root 檔案
    #(WRITABLE_DIRS 已在上一步 chown 給 www-data)
    ssh "$SSH_HOST" "cd \"$RELEASE_DIR\" && $COMPOSE_REMOTE run --rm -u www-data -w \"$RELEASE_DIR/src\" app php artisan migrate --force"
    echo "    php artisan migrate --force 完成"
    ;;
  ci4)
    ssh "$SSH_HOST" "cd \"$RELEASE_DIR\" && $COMPOSE_REMOTE run --rm -u www-data -w \"$RELEASE_DIR/src\" app php spark migrate"
    echo "    php spark migrate 完成"
    ;;
  php|node)
    echo "    stack=$STACK 無 migration,跳過。"
    ;;
esac

# ---------- [7/10] 記錄前一 release,原子切換 current ----------
echo "==> [7/10] 原子切換 current"
PREV="$(ssh "$SSH_HOST" "readlink /srv/$SITE/current 2>/dev/null" || true)"
if [ -n "$PREV" ]; then
  echo "    切換前 current -> $PREV"
else
  echo "    首次部署,無前一 release"
fi

# Caddyfile 變更偵測:caddy 的 bind mount 在容器建立時釘死舊 release 的 inode,
# 之後的 Caddyfile 變更不 recreate caddy 不會生效
CADDY_CHANGED=0
if [ -n "$PREV" ]; then
  if ! ssh "$SSH_HOST" "diff -q \"/srv/$SITE/current/deploy/Caddyfile\" \"$RELEASE_DIR/deploy/Caddyfile\" >/dev/null 2>&1"; then
    CADDY_CHANGED=1
    echo "    偵測到 Caddyfile 變更,啟動後將 recreate caddy"
  fi
fi

# 相對目標 + 原子切換(容器內才解析得到;mv -T 消除非原子窗口;
# ln -sfn 讓前次中斷殘留的 current.tmp 不會擋路)
ssh "$SSH_HOST" "cd /srv/$SITE && ln -sfn \"releases/$TS\" current.tmp && mv -T current.tmp current"
echo "    current -> releases/$TS"

# ---------- [8/10] 啟動服務 ----------
echo "==> [8/10] 啟動服務"
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

# 啟用了 queue worker(服務名 worker)的站:換版後必須重啟,否則 worker 繼續跑舊 release 程式碼
if ssh "$SSH_HOST" "cd /srv/$SITE/current && $COMPOSE_REMOTE ps --services | grep -qx worker"; then
  ssh "$SSH_HOST" "cd /srv/$SITE/current && $COMPOSE_REMOTE restart worker"
  echo "    已重啟 queue worker"
fi

# Caddyfile 有變更時 recreate caddy(caddy_data volume 保留憑證,僅數秒中斷)
if [ "$CADDY_CHANGED" -eq 1 ]; then
  ssh "$SSH_HOST" "cd /srv/$SITE/current && $COMPOSE_REMOTE up -d --force-recreate caddy"
  echo "    Caddyfile 有變更,已 recreate caddy"
fi

# ---------- [9/10] 遠端 smoke test 與失敗處理 ----------
echo "==> [9/10] 遠端 smoke test"
set +e
"$SCRIPT_DIR/smoke-test.sh" remote
SMOKE_RC=$?
set -e

if [ "$SMOKE_RC" -eq 2 ]; then
  # 憑證/TLS 可等待型失敗:回滾對此無效,不觸發回滾
  echo "[失敗] remote smoke test 回報憑證/TLS 類失敗(exit code 2)。" >&2
  echo "       此類失敗回滾無效,不執行回滾;current 維持 releases/$TS。" >&2
  echo "       診斷建議:" >&2
  echo "       1. 看 Caddy log:ssh $SSH_HOST 'cd /srv/$SITE/current && $COMPOSE_REMOTE logs caddy'" >&2
  echo "       2. 檢查 DNS:dig +short $DOMAIN;dig +short www.$DOMAIN" >&2
  exit 2
fi

if [ "$SMOKE_RC" -ne 0 ]; then
  echo "[失敗] remote smoke test 未通過(exit code $SMOKE_RC),進入失敗處理。" >&2
  if [ -n "$PREV" ]; then
    echo "==> 回滾:原子切回 $PREV"
    ssh "$SSH_HOST" "cd /srv/$SITE && ln -sfn \"$PREV\" current.tmp && mv -T current.tmp current"
    ssh "$SSH_HOST" "cd /srv/$SITE/current && $COMPOSE_REMOTE up -d"
    case "$STACK" in
      php|ci4|laravel)
        ssh "$SSH_HOST" "cd /srv/$SITE/current && $COMPOSE_REMOTE exec -T app reload-php"
        ;;
      node)
        ssh "$SSH_HOST" "cd /srv/$SITE/current && $COMPOSE_REMOTE restart app"
        ;;
    esac
    if ssh "$SSH_HOST" "cd /srv/$SITE/current && $COMPOSE_REMOTE ps --services | grep -qx worker"; then
      ssh "$SSH_HOST" "cd /srv/$SITE/current && $COMPOSE_REMOTE restart worker"
    fi
    echo "[結果] 已回滾,migration 未倒轉,目前 DB 狀態需人工判斷。" >&2
    echo "[結果] 失敗原因:remote smoke test 未通過(exit code $SMOKE_RC);失敗 release:releases/$TS(已保留)。" >&2
  else
    echo "==> 首次部署失敗:docker compose down,保留現場供診斷,不執行回滾。"
    ssh "$SSH_HOST" "cd /srv/$SITE/current && $COMPOSE_REMOTE down"
    echo "[結果] 首次部署失敗,現場已保留(/srv/$SITE/releases/$TS)。" >&2
    echo "       診斷指引:" >&2
    echo "       1. 檢查 DNS:dig +short $DOMAIN;dig +short www.$DOMAIN(兩者都應指向 EC2 IP)" >&2
    echo "       2. 看 Caddy log:先 ssh $SSH_HOST 'cd /srv/$SITE/current && $COMPOSE_REMOTE up -d' 重新啟動," >&2
    echo "          再 ssh $SSH_HOST 'cd /srv/$SITE/current && $COMPOSE_REMOTE logs caddy'" >&2
    echo "       3. 修正問題後重跑 scripts/deploy.sh" >&2
  fi
  exit 1
fi
echo "    remote smoke test:通過"

# ---------- [10/10] 成功收尾:git tag + 清理舊 releases + 摘要 ----------
echo "==> [10/10] 部署成功,收尾"
git tag "deploy/$SITE/$TS"
echo "    git tag:deploy/$SITE/$TS"

# release 內含 root(vendor)與 www-data(WRITABLE_DIRS)擁有的檔案,ubuntu 直接 rm 會 Permission denied
ssh "$SSH_HOST" "cd /srv/$SITE/releases && ls -1 | sort | head -n -$KEEP_RELEASES | xargs -r -I{} sudo rm -rf -- \"/srv/$SITE/releases/{}\""
echo "    已清理舊 releases,只保留最近 $KEEP_RELEASES 個"

echo ""
echo "========== 部署摘要 =========="
echo "release : $TS"
echo "sha     : $SHA"
echo "branch  : $BRANCH"
echo "網址    : https://$DOMAIN"
if [ -z "$PREV" ]; then
  echo "備註    : 首次部署成功;請依 SOP 將 first_deployed_at 寫入 deploy/state.json 並 commit。"
fi
echo "=============================="
