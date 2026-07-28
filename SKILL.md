---
name: site-deploy
description: 客戶網站從本機 Docker 開發到 EC2 上線與維運的完整 SOP:scaffold 新專案、本機測試、主機 provision、DNS 閘門、部署、回滾。僅由使用者以 /site-deploy 明確觸發。
disable-model-invocation: true
---

# site-deploy — 客戶網站開發與 EC2 部署 SOP

一台 EC2 一個站;image 只燒核心(php-fpm+nginx 或 node runtime),主程式 mount 在 host;
遠端外殼 Caddy 管 SSL;PostgreSQL 存 named volume;排程一律 systemd timer。

## 觸發後的第一件事(必做,不得跳過)

1. 讀 `deploy/state.json`。不存在 → 全新專案,準備走 Phase 0。
2. 判斷生命週期:`milestones.first_deployed_at` 為 null → **開發期**;有值 → **維護期**。
3. 對照現實查核(維護期):`ssh $SSH_HOST readlink /srv/$SITE/current` 應存在;不符 → 回報 drift,停下與使用者討論,不硬走流程。
4. 向使用者報告:站名、stack、生命週期、即將執行的階段與動作清單。
5. **取得使用者同意後才開始執行任何動作。**

## 生命週期

| | 開發期 | 維護期 |
|---|---|---|
| 有效階段 | Phase 0–1 | 全部 |
| 部署 | 鎖住;使用者明確說「要上線」才啟動一次性序列 Phase 2→3→4 | 改動完成且本機 smoke 通過後,**詢問**是否部署,不自動部署 |
| DB/migration | 可任意重建、squash | 向前相容;破壞性操作先經使用者確認 |
| smoke-routes | 隨開發演進維護 `deploy/smoke-routes.txt` | 固定;部署前後皆跑 |

里程碑(`scaffolded_at`、`provisioned_at`、`dns_verified_at`、`first_deployed_at`)皆為一次性寫入並 commit;日常部署不改 state.json。

## 階段總覽

| Phase | 內容 | 主要檔案 |
|---|---|---|
| 0 scaffold | 新專案骨架 | `templates/<stack>/`、`templates/common/` |
| 1 local-dev | 本機開發與驗證 | `scripts/smoke-test.sh local` |
| 2 provision | 首次主機建置 | `scripts/provision.sh`、`references/provision.md`、`references/ec2-checklist.md` |
| 3 dns-gate | 人工 DNS 介入點 | — |
| 4 deploy | 部署(首次與日常同一套) | `scripts/deploy.sh` |
| 5 backup | 佔位,SOP 另案討論後補 | — |
| 6 rollback | 手動回滾 | `scripts/rollback.sh` |

各 stack 細節:`references/php.md`(純 PHP + CI4)、`references/laravel.md`、`references/node.md`。

## Phase 0 — scaffold

1. **向使用者要求專案名稱,不得自行推斷**(不從資料夾名、網域、對話猜)。驗證 `^[a-z][a-z0-9-]*$`、≤20 字元,複誦確認。此名稱是一切資源的命名種子(compose 專案名/volume/遠端目錄/systemd unit/git tag),**scaffold 後凍結**;改名 = named volume 遺棄(資料庫像消失),屬另案資料搬遷,需明確確認。
2. 問網域、stack(php|ci4|laravel|node)。
3. 複製 `templates/<stack>/`(ci4 用 php 目錄)與 `templates/common/` 到專案,全域替換 `{{SITE}}`、`{{DOMAIN}}`,並依下表放置;填 `deploy/deploy.conf`(含 stack 對應的 `WRITABLE_DIRS`、`APP_PORT_LOCAL`)。
   **本機 port 檢查**:預設 port(php 系 8080、node 3000)先用 `lsof -nP -iTCP:<port> -sTCP:LISTEN` 確認未被其他專案佔用;已佔用就換一個空閒 port,`compose.override.yml` 的 ports 與 `deploy.conf` 的 `APP_PORT_LOCAL` **必須同步改**。postgres 預設不對 host 開 port(app 走 docker 網路),要用 GUI 直連 DB 才解開 override 內的註解。

   | 模板檔案 | 放到專案 |
   |---|---|
   | `<stack>/Dockerfile`、`nginx.conf`、`php.ini`、`php.dev.ini`、`entrypoint.sh`、`reload-php` | `docker/` |
   | `<stack>/compose.yml`、`compose.override.yml`、`compose.prod.yml` | 專案根 |
   | `<stack>/Caddyfile` | `deploy/` |
   | `<stack>/.env.example` | 專案根 |
   | `laravel/systemd/*` | `deploy/systemd/` |
   | `common/gitignore` | `.gitignore`(改名) |
   | `common/deploy.conf.example` | `deploy/deploy.conf` |
   | `common/state.json.tmpl` | `deploy/state.json` |
   | `common/smoke-routes.txt` | `deploy/smoke-routes.txt` |
   | `common/CLAUDE.md.tmpl` | `CLAUDE.md` |
   | `common/README.site.md.tmpl` | `README.md` |
4. 初始化 `src/`:純 PHP → 建最小 `src/public/index.php`;ci4/laravel → 用容器跑 `composer create-project`(對齊 image 的 PHP 版本);node → `create-next-app` 或使用者指定。app 程式根一律 `src/`,php 系 docroot 一律 `src/public`。
5. 產 `.env`(本機開發用)並引導填值;同時產 `deploy/.env.production`:APP_ENV=production、APP_DEBUG=false、APP_URL=https://網域、**隨機 DB 密碼**(ci4 → CI_ENVIRONMENT=production;node → NODE_ENV=production)。兩檔都在 .gitignore,`deploy/.env.production` 是日後上線唯一的 .env 來源。
6. 寫 `deploy/state.json`(`scaffolded_at` = 今日、`stack` = 所選 stack,模板值為 null 必須填掉)→ `git init` + 首次 commit。

## Phase 1 — local-dev

`docker compose up -d` 開發(本機自動吃 override:直開 port、無 caddy、OPcache validate 開)。
部署前置條件,兩者缺一不可:
1. `scripts/smoke-test.sh local` 全綠(容器 healthy、smoke-routes 全過、migration 可跑)。
2. git working tree clean。

## Phase 2 — provision(首次,冪等可重跑)

前置:人已依 `references/ec2-checklist.md` 開好 EC2(Ubuntu 24.04、SG 只開 22/80/443、SSH 金鑰)。

**SSH 連線關卡(正式上線前必做,不得假設已存在)**:向使用者索取兩樣東西——
1. 連線資訊 **`user@ip`**(如 `ubuntu@52.1.2.3`)
2. **`.pem` 金鑰檔路徑**(如 `~/.ssh/acme-prod.pem` 或專案內 `.ssh/xxx.pem`)

拿到後:`chmod 600` 修正 pem 權限 → **徵得使用者同意**後在 `~/.ssh/config` 追加 `Host <站名>` 區塊(HostName=ip、User、IdentityFile=pem 絕對路徑;已有同名區塊則停下確認,不靜默覆蓋)→ `SSH_HOST=<站名>` 寫入 `deploy/deploy.conf` 並 commit → `ssh <站名> exit` 驗證連得上才續行。
pem 在專案目錄內時,確認 `.gitignore` 的 `.ssh/`、`*.pem` 生效(rsync 亦已排除,金鑰絕不上遠端)。

執行 `scripts/provision.sh`:裝 docker、建 `/srv/<site>` 結構、2G swap、上傳 `.env.production` → `shared/.env`(已存在不覆蓋)、chown uploads(php 系 82 = alpine 的 www-data、node 1000)、安裝 systemd units(如有)。
完成 → 寫 `provisioned_at` + commit。

## Phase 3 — dns-gate(人工介入點)

1. 輸出 EC2 公網 IP 與需要的記錄:`A @ → IP`、`A www → IP`。
2. **停下,等使用者確認已設定。**
3. `dig +short <domain>` 與 `dig +short www.<domain>` 都回該 IP 才放行 → 寫 `dns_verified_at` + commit。
Caddy 對 ACME 失敗會自動退避重試,DNS 慢生效只是暫時拿不到憑證,不會壞。

## Phase 4 — deploy

執行 `scripts/deploy.sh`。首次與日常**同一套流程**,全程不依賴任何已運行的 app 容器。流程(腳本已實作,這裡是你要能解讀輸出的地圖):

前置(smoke 綠 + tree clean + 多機防護:遠端 `current/.deploy-meta` 的 SHA 必須是本機 HEAD 祖先,否則 abort)→ rsync 到 `releases/<ts>/` + 寫 `.deploy-meta` → 需要時 build + `up -d postgres` 等 health → 一次性容器(`run --rm -w <新release>/src`)裝依賴(node 為 `npm ci --include=dev && build && npm prune --omit=dev`)→ 每-release chown(WRITABLE_DIRS)→ migration → **原子切 current**(相對 symlink + `mv -T`)→ `up -d` + php 系 reload-php / node 重啟 app → remote smoke(憑證輪詢 120s)→ 成功:git tag `deploy/<site>/<ts>`、清舊 releases。

失敗處理(腳本自動):有前一 release → 切回 + 重啟 + 回報(migration 不自動倒轉,列狀態供人判斷);首次部署 → `compose down` 保留現場,不回滾。**憑證類失敗回滾無效,永不因此回滾**——逾時就查 Caddy log 與 DNS。
首次部署成功 → 寫 `first_deployed_at` + commit → 進入維護期。**流程到此可以停**;維護期紀律由之後的改動觸發。

## Phase 5 — backup(佔位)

`/srv/<site>/backups/` 已在 provision 建立。備份 SOP 另案討論後補;在那之前若使用者要求備份,先手動 `pg_dump` + tar uploads 到 backups/,並提醒此非正式流程。

## Phase 6 — rollback(手動觸發)

執行 `scripts/rollback.sh`:列出 releases(含各自 `.deploy-meta` 的 SHA/branch/時間/操作機)→ 使用者選定 → 原子切 symlink → 重啟(php 系含 reload-php)→ remote smoke。
**DB migration 不自動回滾**;涉及 schema 的回退需使用者確認處置。

## 技術陷阱(絕不可違反)

1. **bind mount 在容器啟動時解析 symlink** → 必須 mount `/srv/<site>` 整層,nginx root 指 `current/src/public`,切 symlink 才即時生效(node 換版必重啟容器,無此問題)。
2. **current 必須在容器內解析得到** → 一律相對目標 + 原子切換:`ln -s "releases/<ts>" current.tmp && mv -T current.tmp current`;compose 必須容器內外同路徑掛 `/srv/<site>`(也是 `run --rm -w` 成立的前提)。
3. **uid 兩層** → 一次性:provision chown `shared/uploads`;每-release:rsync 出來的 release 屬 uid 1000,CI4 `writable/`、Laravel `bootstrap/cache`+`storage` 需在切換前 chown 給容器的 www-data(deploy.sh 依 WRITABLE_DIRS 以名稱 chown;alpine 版 php image 內是 uid 82,不是 Debian 的 33)。
4. **PHP realpath cache**(TTL 120s,不受 OPcache 設定控制)→ php 系換版後 reload php-fpm **必要不可省**;nginx 一律用 `$realpath_root` 傳 SCRIPT_FILENAME。
5. **compose 專案名寫死 `name: <site>`** → 任何目錄下跑 compose 都對到同組 volume/網路;沒有它,每次部署會生出新 volume。
6. **分鐘級 systemd timer 必設 `AccuracySec=1s`**(預設 1min 精度會讓 `dailyAt` 類任務機率性漏跑)。
7. rsync 只寫全新 `releases/<ts>/`,絕不對 `shared/` 用 `--delete`。

## 守則

- 觸發後先報告現況與計畫,**經使用者同意才開跑**。
- scaffold 必須開口要專案名稱並複誦確認;名稱凍結後不得擅改。
- 正式上線前必須向使用者索取 `user@ip` 與 `.pem` 路徑;改動 `~/.ssh/config` 前徵得同意;pem 絕不進 git、絕不 rsync 上遠端。
- 絕不在遠端直接改 `src/`;所有變更一律本機 → 部署。部署失敗以回滾收尾,不在遠端現場修。
- `.env` 不進 git;不覆蓋遠端既有 `shared/.env`,除非使用者明確指示。
- 破壞性操作(還原/重建 DB、降版、刪 volume、改名)一律先向使用者確認。
- 每階段有完成條件,未達成不進下一階段;PG major 版本 pin 死,升級屬另案(dump/restore)。
- 多機協作:ancestor 檢查擋下的部署,先同步程式碼再來;確要覆蓋須使用者明確確認(`--force-divergent`)。
