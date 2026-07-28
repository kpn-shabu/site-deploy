# Node.js 分支細節(Next.js 等)

image:`node:22-slim`;workdir `/srv/{{SITE}}/current/src`;prod command `npm run start`(port 3000);
Caddy 反代 `app:3000`。`.next/`、`dist/`、`node_modules/` 不進 git、不 rsync。

## 為何 Node 不能照 PHP 純 rsync

PHP 的 `vendor/` 是純 PHP 檔案,跨平台可直接搬;Node 的 `node_modules/` 內含
原生二進位(sharp、esbuild、swc、bcrypt…),Mac arm64 裝好的搬到 EC2 x86_64
必定載入失敗。且 Next.js 等框架必須經 build 產出 `.next/`,產物依平台與環境而異。
因此依賴安裝與 build 一律在**目標機的一次性容器內**原地執行(與 image 原地 build
同一精神),架構差異自動消解;rsync 只搬原始碼。

## 三段式安裝(deploy.sh 於一次性容器內執行)

```bash
docker compose -f compose.yml -f compose.prod.yml run --rm --no-deps \
  -w "/srv/{{SITE}}/releases/<ts>/src" app \
  sh -c 'npm ci --include=dev && npm run build && npm prune --omit=dev'
```

三段各自的理由,順序不可換:

1. `npm ci --include=dev`——遠端 `shared/.env` 設了 `NODE_ENV=production`,
   此時 `npm ci` 會**靜默略過 devDependencies**(不報錯、不警告);而 build 需要的
   typescript、tailwindcss 等幾乎都在 devDependencies,缺了 build 直接失敗。
   `--include=dev` 顯式蓋過 NODE_ENV 的隱含行為,**必寫,不可省**。
2. `npm run build`——在 devDependencies 齊備的狀態下產出 `.next/`(或 `dist/`)。
3. `npm prune --omit=dev`——build 完成後剝除 dev 依賴,runtime 只留 production
   依賴:release 體積小(保留 5 份 releases 的磁碟壓力)、攻擊面小。
   放在 build **之後**才不會弄壞第 2 步。

## Next.js:優先 `output: 'standalone'`

`next.config.js` 設 `output: 'standalone'` 後,build 會把 runtime 需要的最小
`node_modules` 複製進 `.next/standalone/`,啟動只跑 `node .next/standalone/server.js`,
不再依賴 release 根的 `node_modules/`——**此時第 3 步 prune 可省**。
注意兩件事:

- `package.json` 的 `start` script 改為 `node .next/standalone/server.js`
  (compose prod command 固定 `npm run start`,由 script 內容決定跑什麼)。
- standalone server 不自帶靜態檔,build 後需補兩個複製:
  `cp -r .next/static .next/standalone/.next/static` 與
  `cp -r public .next/standalone/public`(可寫進 build script 一併執行)。

## swap / OOM

`next run build` 記憶體高峰常超過 1.5G;t3.small(2G RAM)無 swap 時 build 中途
會被 OOM killer 擊殺——症狀是 exit code 137 / SIGKILL,npm 只留下含糊的錯誤。
對策:provision 固定加 2G swap(此為 Node 站 provision 的**必要**步驟);
仍失敗則升 t3.medium。診斷:`free -h` 看 swap 是否存在、
`dmesg | grep -i oom` 確認是否被擊殺。

## 本機 dev:named volume 蓋住 node_modules

compose.override.yml 把整個專案 bind mount 進容器(`.:/srv/{{SITE}}/current`),
若不處理,host(macOS)的 `node_modules/` 會直接蓋掉容器內的 Linux 版依賴,
回到跨平台二進位衝突的老問題。因此 override 以 **named volume 掛在
`src/node_modules`**:mount 優先權讓該目錄與 host 隔離,Linux 依賴留在 volume 內。
volume 的擁有權由 image 決定:docker 初始化 named volume 時沿用 image 內同路徑
目錄的 owner,因此模板 Dockerfile 在切 `USER node` 前預建 `node_modules` 並
chown 給 node——**不可移除這行**,否則 volume 生成 root-owned,
`npm install` 直接 EACCES(既有 volume 需 `docker volume rm` 重建才會套用)。

配套紀律:

- **scaffold 的初始化順序**:骨架先只產原始碼(如
  `npx create-next-app@latest src --skip-install`),再
  `docker compose run --rm --no-deps app npm install` 在容器內裝依賴——
  host(mac arm64)裝的原生二進位與容器不相容,且會被 named volume 蓋住不生效;
  依賴進 volume,`package-lock.json` 經 bind mount 寫回 host 並 **commit 進 git**
  (deploy.sh 的 `npm ci` 需要它)。
- 之後加依賴一律**在容器內**裝:`docker compose exec app npm install <pkg>`
  (寫進 volume,host 的 node_modules 只是 IDE 用的參考,可有可無)。
- 改了 `package.json` 後容器內重跑 `npm install`;volume 內容疑似壞掉時
  `docker compose down && docker volume rm {{SITE}}_<volume名>` 再 up 重裝。
- 本機 command 是 `npm run dev`(override 覆蓋),有 HMR;prod 才是 `npm run start`。

## 換版必重啟容器

php 系靠 nginx `$realpath_root` 每請求解析 symlink,切 `current` 即時生效;
Node **沒有這回事**——node process 啟動時把程式載入記憶體,workdir
`/srv/{{SITE}}/current/src` 的 symlink 也在容器啟動時就解析定了。
因此 deploy.sh 切完 `current` 後**必須重啟 app 容器**
(`docker compose -f compose.yml -f compose.prod.yml restart app`),
新版才會生效;rollback 同理。這是 Node 分支換版的必要步驟,不可省。

## 上傳檔案

程式寫入的使用者上傳**一律**放 `/srv/{{SITE}}/shared/uploads`(容器內外同路徑)。
絕不可寫進 release 內(如 `public/uploads`):release 每次部署全新 rsync、
舊的只保留 5 份,寫在裡面的檔案換版即遺失。本機 override 已把
`./data/uploads` 掛到同一容器路徑,程式碼不需分環境判斷。
