#!/usr/bin/env bash
#
# smoke-test.sh — 本機/遠端共用驗證腳本(site-deploy SOP)
#
# 用法:從專案根執行
#   scripts/smoke-test.sh local    # Phase 1:容器健康 + smoke-routes + migration 乾跑
#   scripts/smoke-test.sh remote   # Phase 4 步驟 8:憑證輪詢 + smoke-routes
#                                  #   + 容器內 symlink 解析 + 環境值斷言
#
# exit code 約定(deploy.sh 依此分流):
#   0 = 全綠
#   1 = 應用層失敗(路由 5xx / 狀態碼不符、容器不健康、migration/symlink/環境檢查失敗)
#       → deploy.sh 據此觸發回滾
#   2 = 憑證/連線逾時(TLS 未就緒、連線不上;Caddy ACME 首簽需時)
#       → 不應回滾——回滾對憑證/DNS 類失敗無效,檢查 caddy log 與 dig
set -euo pipefail

# ---- 參數與設定載入(一律從專案根執行) ----
MODE="${1:-}"
if [[ "$MODE" != "local" && "$MODE" != "remote" ]]; then
  echo "用法:scripts/smoke-test.sh <local|remote>" >&2
  exit 1
fi
if [[ ! -f deploy/deploy.conf ]]; then
  echo "錯誤:找不到 deploy/deploy.conf——請從專案根執行 scripts/smoke-test.sh" >&2
  exit 1
fi
# shellcheck source=/dev/null
source deploy/deploy.conf
: "${SITE:?deploy.conf 缺少 SITE}"
: "${DOMAIN:?deploy.conf 缺少 DOMAIN}"
: "${STACK:?deploy.conf 缺少 STACK}"
: "${APP_PORT_LOCAL:?deploy.conf 缺少 APP_PORT_LOCAL}"
# SSH_HOST 只在 remote 模式檢查——開發期(尚未 provision)SSH_HOST 本來就是空的

case "$STACK" in
  php|ci4|laravel|node) ;;
  *) echo "錯誤:STACK=$STACK 無效(允許:php|ci4|laravel|node)" >&2; exit 1 ;;
esac

ROUTES_FILE="deploy/smoke-routes.txt"
# 遠端 compose 呼叫固定兩檔疊加(契約 §8)
REMOTE_COMPOSE="docker compose -f compose.yml -f compose.prod.yml"

# ---- 共用:逐行讀 smoke-routes.txt 比對狀態碼 ----
# 每行格式:PATH [EXPECTED_STATUS],EXPECTED_STATUS 預設 200;# 為註解,空行跳過。
# 任何 5xx 或與預期不符 → 回傳 1(應用層失敗)。
check_routes() {
  local base_url="$1"
  local line path expected code fail=0
  if [[ ! -f "$ROUTES_FILE" ]]; then
    echo "錯誤:找不到 $ROUTES_FILE" >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"            # 容忍 CRLF
    path=""; expected=""
    read -r path expected _ <<< "$line" || true
    if [[ -z "$path" || "$path" == \#* ]]; then
      continue                       # 跳過空行與註解
    fi
    expected="${expected:-200}"
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$base_url$path" || echo "000")
    if [[ "$code" == "$expected" && "$code" != 5* ]]; then
      echo "    OK   $path → $code"
    else
      echo "    FAIL $path → ${code}(預期 ${expected})"
      fail=1
    fi
  done < "$ROUTES_FILE"
  return "$fail"
}

# ============================================================
# local 模式
# ============================================================
if [[ "$MODE" == "local" ]]; then
  echo "==> [local] 檢查容器狀態(docker compose ps)"
  services=$(docker compose config --services)
  ps_fail=0
  for svc in $services; do
    cid=$(docker compose ps -q "$svc" || true)
    if [[ -z "$cid" ]]; then
      echo "    FAIL service「${svc}」無運行中容器(先 docker compose up -d)"
      ps_fail=1
      continue
    fi
    state=$(docker inspect -f '{{.State.Status}}' "$cid")
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$cid")
    if [[ "$state" == "running" && ( "$health" == "healthy" || "$health" == "no-healthcheck" ) ]]; then
      echo "    OK   ${svc}(state=$state, health=${health})"
    else
      echo "    FAIL ${svc}(state=$state, health=${health})"
      ps_fail=1
    fi
  done
  if (( ps_fail )); then
    echo "錯誤:容器狀態檢查未過 → 應用層失敗" >&2
    exit 1
  fi

  echo "==> [local] 逐條檢查 smoke-routes(http://localhost:${APP_PORT_LOCAL})"
  check_routes "http://localhost:$APP_PORT_LOCAL" || exit 1

  # migration 乾跑檢查(僅 laravel/ci4)。
  # 本機 override 掛 .:/srv/$SITE/current,故本機 ./src 即容器內 /srv/$SITE/current/src。
  case "$STACK" in
    laravel)
      echo "==> [local] migration 乾跑檢查(php artisan migrate:status)"
      if ! docker compose exec -T -w "/srv/$SITE/current/src" app php artisan migrate:status; then
        echo "錯誤:migrate:status 失敗 → 應用層失敗" >&2
        exit 1
      fi
      ;;
    ci4)
      echo "==> [local] migration 乾跑檢查(php spark migrate:status)"
      if ! docker compose exec -T -w "/srv/$SITE/current/src" app php spark migrate:status; then
        echo "錯誤:migrate:status 失敗 → 應用層失敗" >&2
        exit 1
      fi
      ;;
    php|node)
      echo "==> [local] STACK=$STACK 無 migration,跳過乾跑檢查"
      ;;
  esac

  echo "==> local smoke 全綠"
  exit 0
fi

# ============================================================
# remote 模式
# ============================================================
: "${SSH_HOST:?deploy.conf 缺少 SSH_HOST(remote 模式必填)}"
POLL_WINDOW=120    # 輪詢總窗(秒)
POLL_INTERVAL=10   # 輪詢間隔(秒)

echo "==> [remote] 輪詢 https://${DOMAIN}(總窗 ${POLL_WINDOW}s,每 ${POLL_INTERVAL}s 一次)"
deadline=$(( $(date +%s) + POLL_WINDOW ))
reachable=0
while (( $(date +%s) < deadline )); do
  rc=0
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/") || rc=$?
  if (( rc == 0 )); then
    # HTTP 已有回應(不論狀態碼)→ 跳出輪詢,後續逐條比對
    reachable=1
    echo "    HTTP 已有回應(/ → ${code}),結束輪詢"
    break
  fi
  # curl 失敗類型判斷:DNS/連線/TLS 類屬「可等待型」(Caddy ACME 首簽需數秒到數十秒)
  case "$rc" in
    6|7|28|35|51|52|53|54|55|56|58|59|60)
      echo "    可等待型失敗(curl exit=${rc}:DNS/連線/TLS 未就緒),${POLL_INTERVAL}s 後重試"
      ;;
    *)
      echo "    curl exit=${rc}(非典型失敗),仍於時間窗內重試"
      ;;
  esac
  sleep "$POLL_INTERVAL"
done

if (( reachable == 0 )); then
  {
    echo "錯誤:憑證/連線逾時(超過 ${POLL_WINDOW}s 仍無 HTTP 回應)"
    echo "  1. 檢查 caddy log:ssh $SSH_HOST 'cd /srv/$SITE/current && $REMOTE_COMPOSE logs caddy'"
    echo "  2. 檢查 DNS:dig +short ${DOMAIN}、dig +short www.$DOMAIN"
    echo "  此類失敗不應回滾(回滾對憑證/DNS 問題無效;Caddy 對 ACME 失敗會自動退避重試)"
  } >&2
  exit 2
fi

echo "==> [remote] 逐條檢查 smoke-routes(https://${DOMAIN})"
check_routes "https://$DOMAIN" || exit 1

echo "==> [remote] 檢查容器內 current symlink 解析"
# 三層引號:本機展開 $SITE;\$ 保留給容器內 sh 展開。dangling symlink 或目標不存在都算失敗。
inner_check="target=\$(readlink -f /srv/$SITE/current) && [ -n \"\$target\" ] && [ -d \"\$target\" ] && echo \"current -> \$target\""
if ssh "$SSH_HOST" "cd /srv/$SITE/current && $REMOTE_COMPOSE exec -T app sh -c '$inner_check'"; then
  echo "    OK:current 於容器內解析到存在目錄"
else
  echo "    FAIL:current 於容器內解析失敗(斷鏈或目標不存在)→ 應用層失敗" >&2
  exit 1
fi

# 環境值斷言(依 stack;純 php 跳過)
case "$STACK" in
  laravel) ENV_KEY="APP_ENV" ;;
  ci4)     ENV_KEY="CI_ENVIRONMENT" ;;
  node)    ENV_KEY="NODE_ENV" ;;
  php)     ENV_KEY="" ;;
esac
if [[ -n "$ENV_KEY" ]]; then
  echo "==> [remote] 環境值斷言:$ENV_KEY 必須為 production"
  env_val=$(ssh "$SSH_HOST" "cd /srv/$SITE/current && $REMOTE_COMPOSE exec -T app printenv $ENV_KEY" 2>/dev/null | tr -d '\r' || true)
  if [[ "$env_val" == "production" ]]; then
    echo "    OK:$ENV_KEY=production"
  else
    echo "    FAIL:$ENV_KEY=「${env_val:-<未設定>}」(預期 production)→ 應用層失敗" >&2
    exit 1
  fi
else
  echo "==> [remote] STACK=php 無框架環境變數,跳過環境值斷言"
fi

echo "==> remote smoke 全綠"
exit 0
