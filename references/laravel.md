# Laravel 分支細節

適用 `STACK=laravel`,模板 `templates/laravel/`。image 與 php 系同款
(`php:8.3-fpm-alpine` + nginx 單容器、composer、`reload-php`、`$realpath_root`、
OPcache 生產 `validate_timestamps=0`、部署後 reload-php 必要不可省——
細節與 realpath cache 原理見 `references/php.md` §1–§2,此處不重複)。`APP_PORT_LOCAL=8080`。

## 1. 初始化(容器內跑,不用 host PHP)

前置:專案根 `.env` 已存在(可先由 `.env.example` 複製,env_file 缺檔 compose 直接報錯)、
`docker compose build app` 已完成、`src/` 不存在或為空。

```
docker compose run --rm --no-deps -w "/srv/{{SITE}}/current" app \
  composer create-project laravel/laravel src
```

- macOS + Docker Desktop 擁有權自動對映;Linux host 產物屬 root 時 `sudo chown -R $USER src`。
- **刪除 create-project 產生的 `src/.env`**:環境值一律由 compose `env_file` 注入
  (本機 `./.env`、遠端 `/srv/{{SITE}}/shared/.env`),留著徒增雙檔漂移。

### APP_KEY 產生

- `docker compose run --rm --no-deps -w /srv/{{SITE}}/current/src app php artisan key:generate --show`
  (`--show` 只印出、不寫檔)→ 填入本機 `.env`。
- `deploy/.env.production` **另跑一次產生不同的 key**,不與本機共用。
- key 一旦加密過資料(session cookie、encrypted cast)就不可再換。

### .env 要點

`APP_ENV=production`、`APP_DEBUG=false`、`APP_URL=https://{{DOMAIN}}`(本機 `http://localhost:8080`)、
`DB_CONNECTION=pgsql`、`DB_HOST=postgres`、`DB_PORT=5432`;
`DB_DATABASE/DB_USERNAME/DB_PASSWORD` 與 `POSTGRES_DB/USER/PASSWORD` 同值
(env_file 不做插值,兩組 key 都要寫;app 與 postgres 掛同一份 env_file)。

## 2. storage 歸類與 storage:link 的取捨

| 內容 | 位置 | 生命週期 |
|---|---|---|
| `storage/framework/{cache,sessions,views}` | release 內 | framework cache,換版歸零、可拋棄 |
| `storage/logs` | release 內 | 留在各 release;查歷史 log 進舊 release(保留 5 個) |
| 使用者上傳 | `/srv/{{SITE}}/shared/uploads` | 永久,跨 release |

- **不用預設 `storage:link` 流程存使用者上傳**:`php artisan storage:link` 建的
  `public/storage -> storage/app/public` 兩端都在 release 內,換版與清理即遺失,
  與本 SOP 的 release 模型衝突,故捨棄。
- 取而代之(建議作法):
  1. `config/filesystems.php` 加 disk:
     `'uploads' => ['driver' => 'local', 'root' => '/srv/{{SITE}}/shared/uploads', 'url' => env('APP_URL').'/uploads', 'visibility' => 'public']`
  2. repo 內建 symlink `src/public/uploads -> /srv/{{SITE}}/shared/uploads`(絕對目標;
     容器內外同路徑掛載,容器內本機/遠端都解析得到;host 上看似斷鏈屬正常)。
  3. 程式一律 `Storage::disk('uploads')` 存取。
- 取捨:日後改 S3 等 cloud disk 只需換 disk 設定;若堅持沿用 storage:link,
  就得把 `storage/app/public` 另外掛進 shared,增加 mount 複雜度,不採。

## 3. 每-release 權限與 migrate --force 的時機

- `WRITABLE_DIRS="src/bootstrap/cache src/storage"`(deploy.conf)。deploy.sh 於依賴安裝後、
  切 symlink 前執行
  `docker compose ... run --rm -u root app chown -R www-data:www-data src/bootstrap/cache src/storage`。
- `migrate --force` **只出現在 deploy.sh**:
  `run --rm -w /srv/{{SITE}}/releases/<ts>/src app php artisan migrate --force`
  (一次性容器、指向新 release,於切 symlink 前執行)。`--force` 僅為跳過 production 互動確認,
  只在部署流程這個受控點使用;**禁止手動在遠端 exec migrate**。
  本機開發期用不帶 `--force` 的 `php artisan migrate` 自由操作;migration 不自動回滾。

## 4. scheduler(systemd timer)

模板 `templates/laravel/systemd/` → 專案 `deploy/systemd/`,由 provision.sh 安裝並 enable:

- `{{SITE}}-scheduler.timer`:`OnCalendar=*-*-* *:*:00` + `AccuracySec=1s`
- `{{SITE}}-scheduler.service`:`WorkingDirectory=/srv/{{SITE}}/current`、
  `ExecStart=docker compose -f compose.yml -f compose.prod.yml exec -T app php artisan schedule:run`

`AccuracySec=1s` 的原因(三行):
1. systemd timer 預設 `AccuracySec=1min`:實際觸發可在排定點後偏移最多一分鐘(省電合併機制)。
2. `schedule:run` 只執行「當下這一分鐘」匹配的任務;觸發被偏移過分鐘邊界,原定那一分鐘就永遠沒被執行到。
3. `dailyAt`/`hourlyAt` 這類單一分鐘任務因此**機率性靜默漏跑**;`AccuracySec=1s` 把觸發釘在 :00,結構性消除。

## 5. queue worker

`compose.prod.yml` 內含**註解掉的 worker service**(同 image、command `php artisan queue:work`、
工作目錄指向 `current/src`)。

- **何時打開**:程式開始 dispatch queued job、且 `QUEUE_CONNECTION` 改離 `sync`(如 `database`)時
  才取消註解;沒有 queue 需求就保持註解,不跑多餘常駐進程。
- 啟用後的部署紀律:worker 是常駐 PHP 進程,**切 symlink 與 reload-php 都影響不到它**,
  每次部署後必須 `docker compose -f compose.yml -f compose.prod.yml restart worker`,
  否則 worker 繼續跑舊 release 的 code(建議 `queue:work` 加 `--max-time=3600` 自我輪替兜底)。

## 6. 部署後優化(config:cache / route:cache)

部署成功(remote smoke 綠)後,由 LLM 以 exec 對線上容器執行:

```
docker compose -f compose.yml -f compose.prod.yml exec -T app \
  sh -c 'cd /srv/{{SITE}}/current/src && php artisan config:cache && php artisan route:cache'
```

- 快取檔落在 `bootstrap/cache/`(release 內)→ 下次部署天然乾淨,無跨版殘留。
- `config:cache` 後 `env()` 只在 config 檔內有效;程式碼中一律用 `config()` 取值。
- 此步驟屬優化、非部署成敗條件,失敗不觸發回滾;跑完建議再打一次 remote smoke 確認。

## 7. 容器需可寫目錄 checklist

| 目錄 | 處理 | 誰處理 |
|---|---|---|
| `src/bootstrap/cache` | 每-release chown www-data(alpine 內 uid 82) | deploy.sh(依 `WRITABLE_DIRS`) |
| `src/storage`(整棵) | 每-release chown www-data(alpine 內 uid 82) | deploy.sh(依 `WRITABLE_DIRS`) |
| `/srv/{{SITE}}/shared/uploads` | 一次性 chown 82 | provision.sh |
| 其餘 release 內容 | 唯讀即可(屬 uid 1000) | 不動 |

本機開發免 chown(macOS Docker Desktop 自動對映擁有權;Linux 本機才需比照處理)。
