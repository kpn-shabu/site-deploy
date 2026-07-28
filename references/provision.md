# provision.sh 原理與失敗排除

目標:把一台「SSH 連得上」的裸 Ubuntu 24.04,弄到「可接受首次部署」。
**冪等,可整支重跑**;跑之前人必須已完成 `references/ec2-checklist.md`。

## 各步驟原理

### 1. 安裝 docker-ce + compose plugin(官方 apt repo)

Ubuntu 內建的 `docker.io` 版本舊、且 compose plugin 打包方式不同;一律改用
Docker 官方 repo:金鑰放 `/etc/apt/keyrings/docker.asc`,source 指向
`download.docker.com/linux/ubuntu noble stable`,再裝
`docker-ce docker-ce-cli containerd.io docker-compose-plugin`。
裝完把 `ubuntu` 加入 `docker` group,免 sudo 操作。

排除:
- `apt update` GPG 錯誤 → 金鑰檔壞了,重新下載 keyring 再試。
- apt lock(`Could not get lock /var/lib/dpkg/lock-frontend`)→ 新機常見,
  cloud-init / unattended-upgrades 還在跑,等幾分鐘重跑即可,不要砍 lock。
- 加 group 後**同一個 SSH session 不會生效**——provision.sh 內後續 docker 指令
  用 sudo 執行;人工驗證時重開一個 ssh session 再試 `docker version`。

### 2. 加 2G swap

`fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap && swapon`,
並寫入 `/etc/fstab` 讓重開機後仍在。Node 站 build 期記憶體高峰會 OOM,
**必須**;PHP 站也加,當保險。冪等:`swapon --show` 已有作用中 swap 即跳過。
排除:`fallocate` 在少數檔案系統不可用 → 換 `dd if=/dev/zero` 產生檔案。

### 3. 建 `/srv/{{SITE}}` 目錄結構

```
/srv/{{SITE}}/{releases,shared/uploads,backups}   # owner: ubuntu
```

`current` symlink **不在此建立**——它由首次 deploy 的原子切換產生;
provision 後沒有 current 是正常狀態。`backups/` 只是佔位(備份 SOP 另案)。

### 4. 上傳 `.env`(不覆蓋原則)

`deploy/.env.production` scp 到 `/srv/{{SITE}}/shared/.env`,
**僅在遠端不存在該檔時**。已存在一律不動:上線後 `.env` 只在遠端改
(輪換過的 DB 密碼、第三方金鑰只存在遠端),覆蓋等於毀掉線上設定。
確要重推需使用者明確指示,人工處理,不走腳本。
排除:scp 失敗先確認本機 `deploy/.env.production` 存在(scaffold 時產製)。

### 5. uploads chown(uid 對照表)

容器內寫檔的 process uid 必須對得上 host 目錄的 owner:

| stack | 容器內寫入者 | uid:gid | 動作 |
|---|---|---|---|
| php / ci4 / laravel | www-data(php-fpm) | 82:82 | `chown -R 82:82 /srv/{{SITE}}/shared/uploads`(alpine 版 image 的 www-data 為 uid 82;33 是 Debian 系) |
| node | node | 1000:1000 | 與 ubuntu 相同,**免做** |

這是**一次性**的;release 內可寫目錄的每-release chown 屬 deploy.sh 職責,
不在 provision 範圍。排除:上線後上傳功能 500/EACCES → 先
`stat -c '%u:%g' /srv/{{SITE}}/shared/uploads` 對照上表。

### 6. 安裝 systemd units(視 stack,現階段僅 Laravel)

把 `deploy/systemd/{{SITE}}-scheduler.service` 與 `.timer` 複製到
`/etc/systemd/system/` → `systemctl daemon-reload` → `enable --now` **timer**
(service 本身不 enable,由 timer 觸發)。timer 模板已訂
`OnCalendar=*-*-* *:*:00` + `AccuracySec=1s`,不可拿掉 AccuracySec。
排除:`systemctl status {{SITE}}-scheduler.timer` 看啟用狀態、
`journalctl -u {{SITE}}-scheduler.service` 看執行紀錄。
注意:service 的 ExecStart 走 `/srv/{{SITE}}/current`,首次部署前觸發會失敗,
屬預期;首次 deploy 完成後自癒。

## 冪等性

每一步都是「先檢查、已達成就跳過」:repo 檔存在則不重寫、swap 作用中則不重加、
目錄存在則不重建、遠端 `.env` 存在則不覆蓋、unit 檔以覆蓋+daemon-reload 收斂。
中途失敗的正確處置:**修掉原因後整支重跑**,不要手工補半套。

## 完成條件(全部通過才算 provision 成功)

在本機以 `ssh $SSH_HOST` 逐項驗證:

1. `docker version && docker compose version` 正常(ubuntu 免 sudo,需新 session)。
2. `swapon --show` 有 2G swap;`free -h` 可見。
3. `ls /srv/{{SITE}}` 有 `releases/`、`shared/`、`backups/`;
   `shared/uploads/` 存在且 owner 符合上方對照表。
4. `/srv/{{SITE}}/shared/.env` 存在,內容為 production 值(APP_ENV=production 等)。
5. Laravel 案:`systemctl list-timers '{{SITE}}-*'` 列得到 scheduler timer。

全數通過 → 寫入 `state.json` 的 `provisioned_at` 並 commit,進 Phase 3(dns-gate)。
