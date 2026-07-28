# site-deploy skill 規格書

> 目的:定義一個 Claude Code skill,涵蓋「幫客戶寫網站 → 本機 Docker 測試 → 部署到客戶專屬 EC2」的完整 SOP。
> 2026-07-28 經使用者最終確認,已進入實作;本 repo 即 skill 本體的開發專案(repo root = skill root)。

## 0. 已定案的前提與約束

1. 本機測試通過才能部署;本機與遠端皆為 Docker。
2. 資料庫 PostgreSQL,資料存 Docker named volume。
3. 上傳等需持久化的內容,bind mount 到 host 目錄。
4. 遠端最外層由 Caddy 管 SSL(Let's Encrypt 自動續約);本機不跑 Caddy。
5. 遠端為 SSH 連入的 Ubuntu 24.04;**EC2 開機、Security Group、金鑰由人先弄好**,skill 只附開機 checklist,自動化從「SSH 連得上」開始。
6. **一台 EC2 一個站**;Caddy 直接是該站 `compose.prod.yml` 裡的一個 service。
7. **每站各自 Dockerfile**;image 在目標機原地 build(本機測試亦用同一份 Dockerfile 自行 build),不需要 registry,Mac arm64 與 EC2 架構差異自動消解。
8. image 只燒核心(php-fpm+nginx 或 node runtime),主程式 mount 在 host。
9. 本機必用 git;GitHub 視案而定(預設流程不依賴 GitHub,傳輸走 rsync over SSH)。
10. 備份:**細節延後討論**;本規格只預留目錄與章節佔位,不展開。
11. 遠端排程一律 systemd timer,不用 crontab。
12. DNS A 記錄由人工設定;skill 負責產出指示與驗證。
13. 支援四種 stack:純手寫 PHP、CodeIgniter 4、Laravel、Node.js(Next.js 等)。
14. Node 分支:image 用官方 node runtime,遠端一次性容器內 `npm ci --include=dev && npm run build && npm prune --omit=dev`(build 需要 devDependencies,prune 在 build 後才剝除);provision 固定加 swap 防 OOM。
15. 單一 skill 含全部階段。
16. **生命週期分兩期**:開發期(scaffold 後在本機迭代)與維護期(首次部署上線後)。skill 以 `deploy/state.json` 記錄里程碑,階段由「是否已首次部署」推導而非人工宣告;流程可以停在「部署到 EC2」——首次上線序列跑完即止,維護期紀律由之後的改動觸發。

## 1. Skill 檔案結構

安裝位置:`~/.claude/skills/site-deploy/`(全域個人 skill,跨客戶專案可用)。

**觸發方式:僅限使用者以 `/site-deploy` 明確觸發**。SKILL.md frontmatter 設 `disable-model-invocation: true`,Claude 不會依意圖自動採用(description 完全不進 context)。配套:因此 scaffold 會在專案根目錄生成精簡 `CLAUDE.md`(見 §2),讓核心紀律在未觸發 skill 時仍然生效。

```
site-deploy/
├── SKILL.md                  # 主 SOP:階段判斷、通用流程、守則
├── references/
│   ├── php.md                # 純 PHP + CI4 分支細節
│   ├── laravel.md            # Laravel 分支細節
│   ├── node.md               # Node.js 分支細節
│   ├── provision.md          # 首次主機建置細節
│   └── ec2-checklist.md      # 給人看的 EC2 開機 checklist
├── templates/
│   ├── php/                  # Dockerfile、nginx.conf、php.ini、compose 三件組、Caddyfile
│   ├── laravel/              # 同上 + scheduler.service/.timer、queue service 片段
│   ├── node/                 # Dockerfile(FROM node 官方)、compose 三件組、Caddyfile
│   └── common/               # .env.example、.gitignore、deploy.conf、smoke-test
└── scripts/
    ├── smoke-test.sh         # 本機/遠端共用的驗證腳本
    ├── deploy.sh             # rsync → build → migrate → 切換 → 驗證 → 失敗回滾
    ├── rollback.sh           # 手動回滾:列 releases、切 symlink、重啟、驗證
    └── provision.sh          # 首次主機建置(冪等,可重跑)
```

原則:**機械且必須精確的步驟寫成腳本;需要判斷的部分寫在 SKILL.md 讓 LLM 執行**。腳本吃 `deploy/deploy.conf` 的參數(站名、網域、SSH host alias、stack 類型)。

## 2. scaffold 產出的專案骨架

```
<project>/
├── docker/
│   ├── Dockerfile            # 每站自己的;php 系 = php-fpm+nginx 單 image,node 系 = FROM node:22-slim
│   ├── nginx.conf            # php 系適用
│   └── php.ini               # php 系適用
├── src/                      # 主程式,bind mount 進容器,不進 image
├── compose.yml               # 基底:name(固定專案名)、app、postgres、healthcheck
├── compose.override.yml      # 本機:直接開 port、掛本機 .env、dev 指令
├── compose.prod.yml          # 遠端:caddy service、不對外開 app port、restart: unless-stopped、掛 shared/;/srv/<site> 以容器內外相同路徑掛進 app
├── deploy/
│   ├── Caddyfile             # 網域、www 轉址、reverse_proxy 到 app
│   ├── deploy.conf           # SITE=、DOMAIN=、SSH_HOST=、STACK=
│   ├── state.json            # 生命週期里程碑(git 追蹤),見 §4
│   └── systemd/              # 視 stack:scheduler.timer 等
├── .env.example              # 必填 key 清單(DB 密碼等)
├── .gitignore                # .env、deploy/.env.production、vendor/、node_modules/、build 產物
├── CLAUDE.md                 # 精簡紀律:本專案由 site-deploy SOP 管理;部署/provision/回滾一律由使用者輸入 /site-deploy 執行;不得直接操作遠端主機
└── README.md                 # 該站部署摘要(網域、主機、特殊事項)
```

關鍵細節:
- `compose.yml` 頂層寫死 `name: <site>`,確保不同 release 目錄下跑 compose(含部署期的 `run --rm`)都對到同一組 named volume(pgdata)、網路與容器,否則每次部署會生出新 volume。
- 本機 `docker compose up` 用 override 直接 `ports: 8080:80`;遠端由 Caddy 反代,app 不對外開 port,Caddy 憑證存 named volume(caddy_data)。
- PostgreSQL 版本在 compose 中 pin 到 major(如 `postgres:16`);major 升級屬另案(dump/restore),SOP 註明不可直接換 tag。

## 3. 遠端目錄結構

```
/srv/<site>/
├── releases/<timestamp>/     # 每次部署一份完整專案(rsync 目的地)
├── current -> releases/…     # symlink;回滾 = 切回上一個
├── shared/
│   ├── .env                  # 首次 scp 上去,之後只在遠端改;容器以 env_file 引用
│   └── uploads/              # 持久化上傳內容,bind mount 進容器
└── backups/                  # 佔位;備份 SOP 另案討論
```

技術陷阱與對策(SKILL.md 必載明):
- **bind mount 對 symlink 的解析發生在容器啟動時**:因此 mount 的是 `/srv/<site>` 整層,容器內 nginx root 指向 `current/src/public`,切 symlink 才會即時生效。Node 分支換版必重啟容器,無此問題。
- **current symlink 必須在容器內解析得到**:deploy.sh/rollback.sh 一律以**相對目標 + 原子切換**建立:`ln -s "releases/<ts>" current.tmp && mv -T current.tmp current`。絕對路徑目標在容器內掛載路徑與 host 不同時會變斷鏈(每個請求 404);`mv -T` 同時消除 `ln -sfn`(unlink+symlink 兩步)的非原子窗口。配套硬性規定:compose 把 `/srv/<site>` 以**容器內外相同路徑**掛進 app 容器——這也是部署指令 `run --rm -w <host路徑>` 能對上路徑的先決條件。smoke-test remote 增列容器內檢查:`readlink -f` current 必須解析到存在的目錄。
- **uid 對映有兩層**。一次性:provision 時 `chown -R 82:82 shared/uploads`(php 系;**alpine 版 php image 的 www-data 是 uid 82,不是 Debian 的 33**;Node 容器 uid 1000 與 ubuntu 相同,免做)。**每-release**:rsync 寫入的 release 整棵屬 ubuntu(uid 1000),凡容器要寫且留在 release 內的目錄,deploy.sh 必須在依賴安裝後、切 symlink 前以名稱 chown www-data(容器內解析為 82)——CI4 的 `writable/`、Laravel 的 `bootstrap/cache`(及留在 release 內的 storage 子目錄);純 PHP 與 Node 免做。references/php.md、laravel.md 各列「容器需可寫目錄」checklist,由 deploy.sh 機械執行。
- **PHP realpath cache**:per-worker、TTL 預設 120 秒、**不受 OPcache 設定控制**;symlink 切換後若不 reload php-fpm,最長兩分鐘內部分請求混跑新舊 release(間歇性 class/function mismatch fatal)。因此 php 系換版後 reload php-fpm 是**必要步驟,不可省略**;且 nginx 模板一律用 `fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name` 與 `DOCUMENT_ROOT $realpath_root`,由 nginx 每請求先解析 symlink,結構性消除混版窗口。
- rsync 只對 `releases/<ts>/` 全新目錄執行,不對 shared/ 使用 `--delete`,結構上杜絕誤刪持久化資料。

## 4. 生命週期與階段流程

### 狀態記錄:`deploy/state.json`

```json
{
  "site": "acme",
  "stack": "laravel",
  "milestones": {
    "scaffolded_at": "2026-07-28",
    "provisioned_at": null,
    "dns_verified_at": null,
    "first_deployed_at": null
  }
}
```

- 階段**推導而非宣告**:`first_deployed_at` 為 null → 開發期;有值 → 維護期。避免「記錄了但忘了改」的漂移。
- 里程碑皆為一次性寫入並 commit;日常部署不寫此檔(最後部署版本由 git tag 與遠端 `current` 推得),避免每次部署產生 commit 噪音。
- skill 進入任何專案的第一步是讀 `state.json`,並對照現實查核(如 state 稱已上線但遠端無 `current` → 回報 drift,不硬走流程)。跨 session 開新對話也由此檔恢復脈絡。

### 兩期行為差異

| | 開發期 | 維護期 |
|---|---|---|
| 有效階段 | Phase 0–1 | 全部 |
| 部署 | 鎖住;使用者明確表示「要上線」才啟動一次性上線序列(Phase 2→3→4),成功後寫入 `first_deployed_at` | 改動完成且本機 smoke 通過後,**詢問**是否部署,不自動部署 |
| DB/migration | 可任意重建、squash | 向前相容;破壞性操作先確認 |
| smoke-test 路由清單 | 隨開發演進維護 | 固定;部署前後皆跑 |

### Phase 0 — scaffold(新專案)
**第一步是向使用者要求並確認「專案名稱」,不得自行推斷**(不從資料夾名、網域、對話脈絡猜)。此名稱是所有資源的命名種子:compose 專案名(`name: <site>`)→ 容器名 `<site>-app-1`、volume `<site>_pgdata`、network;遠端目錄 `/srv/<site>`;systemd unit `<site>-*.timer`;git tag `deploy/<site>/<ts>`;`state.json` 的 `site` 欄位。
- 格式驗證:`^[a-z][a-z0-9-]*$`(小寫開頭、僅小寫英數與連字號),長度合理(建議 ≤ 20 字元),skill 檢查通過並向使用者複誦確認後才往下走。
- **命名一經 scaffold 即凍結**:事後改名等於 compose 換專案名,named volume 會被遺棄(資料庫像消失一樣),遠端目錄與 systemd unit 也要整套搬遷。SKILL.md 載明:如確要改名,屬另案的資料搬遷作業,需使用者明確確認。

確認名稱後:問網域、stack → 從 templates 生成骨架(含精簡 `CLAUDE.md`,讓核心紀律在未觸發 skill 的 session 也生效)→ `git init` + 首次 commit → 引導填 `.env`(本機開發用)。
同時從 `.env.example` 產製 **`deploy/.env.production`**:APP_ENV=production、APP_DEBUG=false、APP_URL=https://<DOMAIN>、隨機產生的 DB 密碼(CI4 對應 CI_ENVIRONMENT=production、Node 對應 NODE_ENV=production);此檔與 `.env` 同列 `.gitignore`,是日後上線的唯一 .env 來源——杜絕「本機 dev 設定被 scp 上線」。

### Phase 1 — local-dev(開發與驗證)
`docker compose up -d` → 開發 → 部署前置條件:
1. `smoke-test.sh local` 全綠:容器 healthy、關鍵路由 HTTP 200、migration 可乾跑(有 migration 的 stack)。
2. git working tree clean(部署的內容必有版控)。
兩者未過,skill 拒絕進入 deploy。

### Phase 2 — provision(首次主機建置,冪等)
前置:人依 `ec2-checklist.md` 開好機(Ubuntu 24.04、SG 只開 22/80/443、SSH 金鑰),並在本機 `~/.ssh/config` 建好 host alias。
步驟:apt 安裝 docker-ce + compose plugin → 建 `/srv/<site>` 目錄結構與權限 → 加 2G swap(Node 站必須;PHP 站也加,保險)→ scp `deploy/.env.production` 到 `shared/.env`(遠端已存在則不覆蓋)→ 安裝該站需要的 systemd units(scheduler 等)。

### Phase 3 — dns-gate(人工介入點)
輸出:EC2 公網 IP + 需要的 A 記錄(`@` 與 `www`)→ **停下等人設定** → `dig +short` 驗證兩筆都指向該 IP 才放行。
註:Caddy 對 ACME 失敗會自動退避重試,就算 DNS 慢生效也只是暫時拿不到憑證,不會壞。

### Phase 4 — deploy(首次與日常共用同一套流程,不依賴任何已運行的 app 容器)
1. 前置檢查:Phase 1 兩條件(smoke 綠 + working tree clean),加上**多機防護**——讀遠端 `current/.deploy-meta` 取線上 SHA(檔不存在=首次部署,跳過);本機必須 `git cat-file -e <sha>` 且 `git merge-base --is-ancestor <sha> HEAD`,否則 abort 並提示「本機不含線上已部署版本,先同步再部署」;有意回退須使用者明確確認才放行。
2. `rsync -az` 專案到 `releases/<ts>/`(排除 `.env`、`.git`、`vendor/`、`node_modules/`、build 產物),並由 deploy.sh 產生 `releases/<ts>/.deploy-meta`(git SHA、branch、時間、操作機 hostname)一併傳上。
3. 首次部署或 `docker/` 有變更時,遠端 `docker compose build`;隨後 `docker compose up -d postgres` 並等 healthcheck 通過。
4. 依賴安裝——一律用**一次性容器 + 指定新 release 工作目錄**,禁止 exec 依附運行中容器:php 系 `docker compose run --rm --no-deps -w /srv/<site>/releases/<ts>/src app composer install --no-dev`;node 系同式執行 `npm ci --include=dev && npm run build && npm prune --omit=dev`(build 需要 devDependencies,prune 於 build 後剝除;Next.js 優先 `output: 'standalone'`)。
5. 每-release 權限(見 §3 uid 對映):CI4/Laravel 對容器需寫入的目錄以名稱 chown www-data(alpine 內 uid 82)。
6. migration:`run --rm -w <新release>/src app php artisan migrate --force`(CI4 同理;向前相容為原則)。
7. **原子切 `current`**(相對目標 + `mv -T`,見 §3)→ `docker compose up -d` → php 系 reload php-fpm,node 系重啟 app 容器。
8. `smoke-test.sh remote`:https/憑證檢查採**輪詢**(總窗 120s、每 10s 重試)——TLS 握手失敗/憑證未簽發屬「可等待型」(Caddy ACME 首簽需數秒到數十秒),逾時僅回報並指向 Caddy log 與 DNS 檢查,**不觸發回滾**(回滾對憑證類失敗無效);HTTP 5xx/關鍵路由錯誤才是觸發回滾的應用層失敗。另驗:容器內 `readlink -f` current 解析正常、環境值正確(APP_ENV=production 等,依 stack)。
9. **失敗處理分兩型**:有前一 release → symlink 原子切回、重啟、回報原因(migration 不自動倒轉,列出狀態供人判斷);**首次部署**(無前一 release)→ `docker compose down`、保留現場供診斷、回報,不執行回滾。deploy.sh 在切換前就記錄是否存在前一 release。
10. 成功:git tag `deploy/<site>/<ts>`;清理只留最近 5 個 releases。

### Phase 5 — backup(佔位)
只建立 `backups/` 目錄與 SKILL.md 章節佔位,註明「備份 SOP 另案討論後補」。

### Phase 6 — rollback(手動觸發)
列出 releases(含各自 `.deploy-meta` 的 SHA、branch、部署時間、操作機)→ 選定 → 原子切 symlink → 重啟(php 系含 reload php-fpm)→ smoke test。載明:DB migration 不自動回滾,涉及 schema 的回退需人工確認。

## 5. 各 stack 分支要點(references/ 內容綱要)

- **純 PHP / CI4**(`php.md`):nginx+php-fpm 單 image;生產 `opcache.validate_timestamps=0`,**部署後 reload php-fpm 為必要步驟不可省略**(realpath cache,見 §3),本機開發才開 validate;CI4 docroot 指 `public/`、`writable/` 每-release chown、logs/cache 留 release 內、使用者上傳歸 shared;列「容器需可寫目錄」checklist 供 deploy.sh 執行。
- **Laravel**(`laravel.md`):`storage:link`、`storage/` 的持久化歸類、`bootstrap/cache` 每-release chown、`migrate --force` 時機、scheduler 用 systemd timer 每分鐘 `docker compose exec -T app php artisan schedule:run`——timer 模板必訂 `OnCalendar=*-*-* *:*:00` + **`AccuracySec=1s`**(systemd 預設 1min 精度,偏移抽到分鐘邊界會讓 `dailyAt`/`hourlyAt` 靜默漏跑;凡分鐘精度的 timer 一律如此,寫入 SKILL.md 通則)、需要 queue 時同 image 加一個 worker service、`config:cache` 等部署後優化。
- **Node.js**(`node.md`):官方 node image、遠端一次性容器內 `npm ci --include=dev → build → npm prune --omit=dev` 三段式(生產環境 NODE_ENV=production 會讓 `npm ci` 靜默略過 devDependencies,必須顯式 `--include=dev`;build 沒有 dev 依賴會直接失敗)、Next.js 優先 `output: 'standalone'`(runtime 只跑 `.next/standalone`,此時 prune 可省)、swap/OOM 註記、`npm run start` 為 prod 指令、Caddy 反代到 app:3000、`.next`/`dist` 不進 git 也不 rsync。

## 6. skill 內建守則

- skill 僅由使用者 `/site-deploy` 觸發(`disable-model-invocation: true`);**觸發後先讀 state.json 報告現況與即將執行的階段,經使用者同意才開跑**,不得觸發即動工。
- scaffold 必須向使用者要求專案名稱並複誦確認,不得自行推斷;名稱凍結後不得擅改(見 Phase 0)。
- 進入專案第一步:讀 `deploy/state.json` 判斷開發期/維護期,並與遠端現實對照。
- 維護期的任何改動,完成後詢問是否部署;部署是對外動作,不自動執行。
- 絕不在遠端直接改 `src/`;所有變更一律本機 → 部署。
- `.env` 不進 git;不覆蓋遠端既有 `.env`,除非使用者明確指示。
- 破壞性操作(還原 DB、降版、刪 volume)一律先向使用者確認。
- 每個階段有明確完成條件,未達成不得進入下一階段。
- 部署失敗以回滾收尾,不在遠端「現場修」。

## 7. 本規格的預設假設(可推翻)

- skill 名稱 `site-deploy`、裝在 `~/.claude/skills/`(全域)。
- 保留 releases 數量 5;swap 2G;www 轉址到 apex。
- PHP 預設 8.3、Node 預設 22 LTS、PostgreSQL 預設 16(各站可在 Dockerfile/compose 改)。
- 多人/多機維護同一站時,Phase 4 的 ancestor 檢查會強制先同步程式碼,實務上需要某種共享管道;無 GitHub 的案子可選在 provision 時於 EC2 建 bare repo 當零成本共享 remote。

## 8. 實作契約(所有 templates / scripts / references 必須遵守的共用約定)

**佔位符**:模板中僅用 `{{SITE}}`、`{{DOMAIN}}` 兩個佔位符,scaffold 時由 LLM 全域替換;其餘參數一律進 `deploy/deploy.conf`。

**模板 → 專案的對應**:`templates/<stack>/Dockerfile|nginx.conf|php.ini|php.dev.ini|entrypoint.sh|reload-php` → 專案 `docker/`;`templates/<stack>/compose*.yml` → 專案根;`templates/<stack>/Caddyfile` → `deploy/`;`templates/laravel/systemd/*` → `deploy/systemd/`;`templates/common/*` → 對應位置(`.gitignore`、`deploy/deploy.conf`、`deploy/state.json`、`deploy/smoke-routes.txt`、`CLAUDE.md`、`README.md`)。`.env.example` 放各 stack 目錄(php 版含 CI4 註解區塊)。每個 stack 目錄**自成一套完整檔案**,scaffold 只複製一個目錄,不做跨目錄組合。

**compose 約定**:
- service 名固定:`app`、`postgres`、`caddy`(caddy 僅 compose.prod.yml);volume 固定:`pgdata`、`caddy_data`;頂層 `name: {{SITE}}`。
- 基底 `compose.yml` **不使用變數插值**(遠端 release 目錄沒有 .env 可供插值);env 一律 `env_file`:override 用 `./.env`,prod 用 `/srv/{{SITE}}/shared/.env`,app 與 postgres 都掛。
- postgres:`postgres:16-alpine`,healthcheck `pg_isready`,volume `pgdata:/var/lib/postgresql/data`。
- ports:本機 php `8080:80`、node `3000:3000`、postgres `127.0.0.1:5432:5432`;prod 只有 caddy 開 `80:80`、`443:443`。
- prod 掛載:`/srv/{{SITE}}:/srv/{{SITE}}`(容器內外同路徑,硬性);caddy 另掛 `./deploy/Caddyfile:/etc/caddy/Caddyfile`(即 current 下的相對路徑)與 `caddy_data:/data`。
- 本機 override 掛載:`.:/srv/{{SITE}}/current`、`./data/uploads:/srv/{{SITE}}/shared/uploads`(`data/` gitignored)→ **容器內路徑本機與遠端完全一致**。

**路徑約定**:app 程式根一律是 `src/`(composer.json、package.json、artisan、spark 都在 src/ 下);php 系 docroot 一律 `src/public`(純 PHP 也是,scaffold 建立 `src/public/index.php`);nginx root 寫死 `/srv/{{SITE}}/current/src/public`。上傳目錄容器內一律 `/srv/{{SITE}}/shared/uploads`。

**php image**(templates/php、templates/laravel 共用同款):`php:8.3-fpm-alpine` + nginx 同一容器;entrypoint `php-fpm -D` 後 `exec nginx -g 'daemon off;'`;內建 `/usr/local/bin/reload-php`(對 php-fpm master 送 USR2);nginx fastcgi 一律 `SCRIPT_FILENAME $realpath_root$fastcgi_script_name`、`DOCUMENT_ROOT $realpath_root`;`location = /healthz { return 200; }`;compose healthcheck 打 `http://localhost/healthz`。OPcache:image 內 `validate_timestamps=0`,本機由 override 掛 `./docker/php.dev.ini`(`validate_timestamps=1`)進 conf.d 覆蓋。擴充至少含 `pdo_pgsql`。

**node image**:`node:22-slim`;workdir `/srv/{{SITE}}/current/src`;prod command `npm run start`(port 3000);本機 override command `npm run dev`,並用 named volume 蓋住 `src/node_modules`(避免 host/容器二進位衝突)。

**Caddyfile**:`{{DOMAIN}}` 反代 `app:80`(php 系)/`app:3000`(node 系);`www.{{DOMAIN}}` 301 到 apex。

**scripts 約定**:bash、`set -euo pipefail`、一律從專案根執行、開頭 `source deploy/deploy.conf`。`deploy.conf` keys:`SITE`、`DOMAIN`、`SSH_HOST`、`STACK`(php|ci4|laravel|node)、`APP_PORT_LOCAL`(8080|3000)、`KEEP_RELEASES=5`、`WRITABLE_DIRS`(空白分隔、相對 release 根;ci4=`src/writable`,laravel=`src/bootstrap/cache src/storage`,php/node 留空)。遠端 compose 呼叫固定 `docker compose -f compose.yml -f compose.prod.yml`;本機固定 `docker compose`(自動吃 override)。symlink 切換固定在 `/srv/$SITE` 下執行 `ln -s "releases/$TS" current.tmp && mv -T current.tmp current`。`.deploy-meta` 為 KEY=VALUE 行:`sha`、`branch`、`deployed_at`、`host`。每-release chown 用 `docker compose ... run --rm -u root app chown -R www-data:www-data <dirs>`(免 sudo)。migration:laravel `php artisan migrate --force`、ci4 `php spark migrate`、php/node 跳過。

**systemd 模板**:單元名 `{{SITE}}-scheduler.service/.timer`;timer `OnCalendar=*-*-* *:*:00` + `AccuracySec=1s`;service `WorkingDirectory=/srv/{{SITE}}/current`、`ExecStart=docker compose -f compose.yml -f compose.prod.yml exec -T app php artisan schedule:run`。

**smoke-routes.txt**:每行 `PATH [EXPECTED_STATUS]`,預設 200,`#` 為註解。smoke-test.sh `local` 模式打 `http://localhost:$APP_PORT_LOCAL`,`remote` 模式打 `https://$DOMAIN` 並依規格 Phase 4 步驟 8 輪詢與分型。
