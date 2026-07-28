# 純 PHP + CodeIgniter 4 分支細節

適用 `STACK=php` 與 `STACK=ci4`,兩者共用 `templates/php/`(image、compose、Caddyfile 完全相同);
差異只在 `src/` 初始化方式、`WRITABLE_DIRS` 與 migration 指令。`APP_PORT_LOCAL=8080`。

## 1. image 構成(php-fpm + nginx 單容器)

- 基底 `php:8.3-fpm-alpine`,同一容器再裝 nginx;entrypoint 先 `php-fpm -D`,再 `exec nginx -g 'daemon off;'`。
- entrypoint 收到參數時直接 `exec "$@"`——deploy.sh 的一次性容器
  (`docker compose ... run --rm --no-deps -w <release>/src app composer install --no-dev`)靠這個機制運作。
- image 內建 composer 與 `/usr/local/bin/reload-php`:對 php-fpm master 送 `USR2`,重生全部 worker;
  nginx 不動、服務不中斷。deploy.sh / rollback.sh 於切 symlink 後呼叫:
  `docker compose -f compose.yml -f compose.prod.yml exec -T app reload-php`
- PHP 擴充至少含 `pdo_pgsql`;**CI4 的 Postgre driver 實際使用 `pgsql` 擴充**,
  模板 Dockerfile 已同時內建 `pdo_pgsql` 與 `pgsql`,純 PHP 站多裝 pgsql 無害。
- nginx fastcgi 一律 `SCRIPT_FILENAME $realpath_root$fastcgi_script_name`、`DOCUMENT_ROOT $realpath_root`
  (每請求先解析 symlink,消除切版混跑窗口);`location = /healthz { return 200; }` 供
  compose healthcheck 打 `http://localhost/healthz`。

## 2. OPcache 與部署後 reload(必要,不可省略)

- 生產(image 內建):`opcache.validate_timestamps=0`——不做時戳檢查、效能最佳;
  代價是換版後必須 reload 才會載入新 code。
- 本機:override 掛 `./docker/php.dev.ini`(`opcache.validate_timestamps=1`)進 conf.d 覆蓋,改檔即生效。
- realpath cache 原理(reload 為何不可省,三行):
  1. php-fpm 每個 worker 各有一份 realpath cache(路徑 → 實體路徑),TTL 預設 120 秒,**不受任何 OPcache 設定控制**。
  2. 切 current symlink 後,舊 worker 在 TTL 內仍把 current 解析到舊 release,新舊 code 混跑,產生間歇性 class/function mismatch fatal。
  3. `reload-php`(USR2)重生全部 worker,cache 隨 worker 消滅即刻清空;nginx 的 `$realpath_root` 只擋住入口,PHP 內部 include 與 OPcache 仍在 PHP 側,故 reload 不可省。

## 3. docroot 與純 PHP 骨架

docroot 一律 `src/public`,nginx root 寫死 `/srv/{{SITE}}/current/src/public`(本機與遠端一致,不可改)。

純 PHP 由 scaffold 建立最小骨架:

```
src/
├── public/          # 唯一對外目錄,nginx docroot
│   └── index.php    # 最小起點,之後自由發展
└── lib/             # 非公開程式(選用):設定、共用函式放這,不放 public
```

- 純 PHP:`WRITABLE_DIRS` 留空、無 migration(deploy.sh 自動跳過)。
- 程式要寫檔一律寫 `/srv/{{SITE}}/shared/uploads`(見 §5),不得寫 release 目錄。

## 4. CI4 初始化與設定

### composer create-project(容器內跑,不用 host PHP)

前置:專案根 `.env` 已存在(可先由 `.env.example` 複製,compose 的 env_file 缺檔會直接報錯)、
`docker compose build app` 已完成、`src/` 不存在或為空。

```
docker compose run --rm --no-deps -w "/srv/{{SITE}}/current" app \
  composer create-project codeigniter4/appstarter src
```

- macOS + Docker Desktop 擁有權自動對映;Linux host 產物屬 root 時,執行後 `sudo chown -R $USER src`。
- **不建立 `src/.env`**(CI4 自帶的 dotenv 檔):環境值一律由 compose `env_file` 注入
  (本機 `./.env`、遠端 `/srv/{{SITE}}/shared/.env`),避免雙檔漂移。

### .env 對應(CI4 直接讀環境變數)

| key | 本機 `.env` | `deploy/.env.production` |
|---|---|---|
| `CI_ENVIRONMENT` | `development` | `production` |
| `app.baseURL` | `http://localhost:8080/` | `https://{{DOMAIN}}/` |
| `database.default.hostname` | `postgres` | `postgres` |
| `database.default.port` | `5432` | `5432` |
| `database.default.DBDriver` | `Postgre` | `Postgre` |
| `database.default.database` / `username` / `password` | 與 `POSTGRES_DB/USER/PASSWORD` 同值 | 同左 |

env_file 不做變數插值:`database.default.*` 與 `POSTGRES_*` 兩組 key 都要寫、值保持一致
(app 與 postgres 掛同一份 env_file)。

### migration(spark migrate)

- 遠端指令固定 `php spark migrate`,**只由 deploy.sh 以一次性容器執行**
  (`run --rm -w /srv/{{SITE}}/releases/<ts>/src app php spark migrate`),不 exec 進運行中容器。
- 本機開發期先 `docker compose up -d`,再
  `docker compose run --rm -w /srv/{{SITE}}/current/src app php spark migrate`;
  開發期可自由重建/squash,維護期以向前相容為原則。

## 5. writable/、logs/cache 與使用者上傳

- `WRITABLE_DIRS="src/writable"`(deploy.conf)。deploy.sh 每-release 依此於依賴安裝後、
  切 symlink 前執行 `docker compose ... run --rm -u root app chown -R www-data:www-data src/writable`。
- `writable/` 底下 cache/logs/session/debugbar **留在 release 內**:換版即歸零,屬可拋棄資料,
  不做跨 release 持久化;查歷史 log 到舊 release 目錄找(保留最近 5 個)。
- **使用者上傳一律存 `/srv/{{SITE}}/shared/uploads`**(容器內絕對路徑,本機/遠端一致),
  不得用 `writable/uploads/`——release 會被清理,放那裡的檔案會消失。
- 對外提供上傳檔(建議作法):repo 內建 symlink `src/public/uploads -> /srv/{{SITE}}/shared/uploads`
  (絕對目標;容器內外同路徑掛載,故容器內必解析得到;git 與 rsync 都保留 symlink;
  host 上看似斷鏈屬正常現象)。

## 6. 容器需可寫目錄 checklist

| 目錄 | 純 PHP | CI4 | 誰處理 |
|---|---|---|---|
| `src/writable`(整棵) | — | 每-release chown www-data(alpine 內 uid 82) | deploy.sh(依 `WRITABLE_DIRS`) |
| `/srv/{{SITE}}/shared/uploads` | 需要 | 需要 | provision.sh 一次性 chown 82 |
| 其餘 release 內容 | 唯讀即可 | 唯讀即可 | 不動(屬 uid 1000) |

本機開發免 chown(macOS Docker Desktop 自動對映擁有權;Linux 本機才需比照處理)。
