#!/usr/bin/env bash
#
# provision.sh — Phase 2 首次主機建置(site-deploy SOP)
#
# 用法:從專案根執行 scripts/provision.sh
# 特性:冪等,可重複執行;已完成的步驟自動偵測並跳過。
# 前置:人已依 references/ec2-checklist.md 開好 EC2(Ubuntu 24.04、
#       Security Group 只開 22/80/443、SSH 金鑰),
#       且本機 ~/.ssh/config 已建立 SSH_HOST 對應的 host alias。
set -euo pipefail

# ---- 設定載入(一律從專案根執行) ----
if [[ ! -f deploy/deploy.conf ]]; then
  echo "錯誤:找不到 deploy/deploy.conf——請從專案根執行 scripts/provision.sh" >&2
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
  *) echo "錯誤:STACK=$STACK 無效(允許:php|ci4|laravel|node)" >&2; exit 1 ;;
esac

echo "==> provision 開始:SITE=$SITE STACK=$STACK SSH_HOST=$SSH_HOST"

# ---- [1/8] SSH 連線與作業系統檢查 ----
echo "==> [1/8] 檢查 SSH 連線與作業系統"
if ! ssh -o ConnectTimeout=10 "$SSH_HOST" true; then
  echo "錯誤:無法以 ssh 連上 ${SSH_HOST}——檢查 ~/.ssh/config 的 host alias 與 Security Group(port 22)" >&2
  exit 1
fi
os_info=$(ssh "$SSH_HOST" '. /etc/os-release && printf "%s %s" "$ID" "$VERSION_ID"')
if [[ "$os_info" != ubuntu\ 24* ]]; then
  echo "錯誤:遠端不是 Ubuntu 24(偵測到:${os_info})——本 SOP 僅支援 Ubuntu 24.04" >&2
  exit 1
fi
echo "    OK:$os_info"

# ---- [2/8] 安裝 Docker(官方 apt repo;已安裝則跳過) ----
echo "==> [2/8] 安裝 Docker(docker-ce + docker-compose-plugin)"
ssh "$SSH_HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "    略過:docker 與 compose plugin 已安裝($(docker --version))"
else
  # Docker 官方 apt repo(https://docs.docker.com/engine/install/ubuntu/)
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-compose-plugin
  echo "    已安裝:$(docker --version)"
fi
# 讓 ubuntu 使用者免 sudo 操作 docker(冪等;群組變更需重新登入 ssh 才生效)
sudo usermod -aG docker ubuntu
REMOTE

# ---- [3/8] 建立 /srv/<site> 目錄結構 ----
echo "==> [3/8] 建立 /srv/$SITE 目錄結構"
ssh "$SSH_HOST" "sudo mkdir -p /srv/$SITE/{releases,shared/uploads,backups} \
  && sudo chown ubuntu:ubuntu /srv/$SITE /srv/$SITE/releases /srv/$SITE/shared /srv/$SITE/backups"
echo "    OK:/srv/$SITE/{releases,shared/uploads,backups}"

# ---- [4/8] 2G swap(防 OOM;已存在則跳過) ----
echo "==> [4/8] 設定 2G swapfile"
ssh "$SSH_HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
# 以「swap 是否作用中」判斷冪等,而非檔案存在與否——
# 前次若在 fallocate 之後中斷,/swapfile 存在但未啟用,仍需走啟用流程
if swapon --show=NAME --noheadings | grep -qx /swapfile; then
  echo "    略過:/swapfile 已作用中"
else
  if [ ! -f /swapfile ]; then
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
  fi
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo "    已建立並啟用 2G swap"
fi
# fstab 開機自動掛載(冪等)
if ! grep -q '^/swapfile ' /etc/fstab; then
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
  echo "    已寫入 /etc/fstab"
fi
REMOTE

# ---- [5/8] 上傳 .env.production → shared/.env(遠端已存在則不覆蓋) ----
echo "==> [5/8] 上傳 deploy/.env.production → /srv/$SITE/shared/.env"
if ssh "$SSH_HOST" "[ -f /srv/$SITE/shared/.env ]"; then
  echo "    略過:遠端 /srv/$SITE/shared/.env 已存在,不覆蓋(如需更新,直接在遠端修改)"
else
  if [[ ! -f deploy/.env.production ]]; then
    echo "錯誤:本機缺少 deploy/.env.production(Phase 0 scaffold 應已產出)" >&2
    exit 1
  fi
  scp -q deploy/.env.production "$SSH_HOST:/srv/$SITE/shared/.env"
  ssh "$SSH_HOST" "chmod 600 /srv/$SITE/shared/.env"
  echo "    已上傳 shared/.env(權限 600)"
fi

# ---- [6/8] shared/uploads 擁有者(依 stack 對映容器內 uid) ----
echo "==> [6/8] 設定 shared/uploads 擁有者"
case "$STACK" in
  php|ci4|laravel) uploads_owner="82:82" ;;    # www-data:php:8.3-fpm-alpine 內為 uid 82(33 是 Debian 系)
  node)            uploads_owner="1000:1000" ;; # node 容器內 uid,與 ubuntu 相同
esac
ssh "$SSH_HOST" "sudo chown -R $uploads_owner /srv/$SITE/shared/uploads"
echo "    OK:chown -R $uploads_owner shared/uploads(STACK=${STACK})"

# ---- [7/8] 安裝 systemd units(deploy/systemd/ 存在才做) ----
echo "==> [7/8] 安裝 systemd units"
unit_files=()
for f in deploy/systemd/*.service deploy/systemd/*.timer; do
  if [[ -e "$f" ]]; then
    unit_files+=("$f")
  fi
done
if (( ${#unit_files[@]} > 0 )); then
  # scp 無法直寫 root 目錄:先放遠端 /tmp,再 sudo install 進 /etc/systemd/system/
  scp -q "${unit_files[@]}" "$SSH_HOST:/tmp/"
  for f in "${unit_files[@]}"; do
    unit=$(basename "$f")
    ssh "$SSH_HOST" "sudo install -m 644 /tmp/$unit /etc/systemd/system/$unit && rm -f /tmp/$unit"
    echo "    已安裝:/etc/systemd/system/$unit"
  done
  ssh "$SSH_HOST" "sudo systemctl daemon-reload"
  for f in deploy/systemd/*.timer; do
    if [[ -e "$f" ]]; then
      timer=$(basename "$f")
      ssh "$SSH_HOST" "sudo systemctl enable --now $timer"
      echo "    已啟用 timer:$timer"
    fi
  done
else
  echo "    略過:deploy/systemd/ 不存在或無 unit 檔(此 stack 不需要)"
fi

# ---- [8/8] 完成摘要與下一步 ----
# 嘗試取得 EC2 公網 IP(IMDSv2;失敗不阻斷流程)
public_ip=$(ssh "$SSH_HOST" '
  token=$(curl -fsS --max-time 3 -X PUT http://169.254.169.254/latest/api/token \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
  curl -fsS --max-time 3 -H "X-aws-ec2-metadata-token: $token" \
    http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true
')
if [[ -z "$public_ip" ]]; then
  public_ip="<EC2 公網 IP,請自 AWS console 查>"
fi

echo ""
echo "==> [8/8] provision 完成摘要"
echo "    - Docker engine + compose plugin:已就緒"
echo "    - /srv/$SITE/{releases,shared/uploads,backups}:已建立"
echo "    - 2G swap:已啟用(含 fstab)"
echo "    - shared/.env:見步驟 [5/8] 輸出(已上傳或沿用遠端既有)"
echo "    - shared/uploads 擁有者:$uploads_owner"
if (( ${#unit_files[@]} > 0 )); then
  echo "    - systemd units:已安裝並啟用 timer"
fi
echo ""
echo "下一步(Phase 3 dns-gate,人工介入點):"
echo "  1. 至 DNS 服務商設定 A 記錄:"
echo "       A  @    → $public_ip"
echo "       A  www  → $public_ip"
echo "  2. 驗證 dig +short $DOMAIN 與 dig +short www.$DOMAIN 皆回該 IP 後,"
echo "     才可執行 scripts/deploy.sh(Phase 4)。"
echo "  3. 里程碑:寫入 deploy/state.json 的 provisioned_at 並 commit。"
