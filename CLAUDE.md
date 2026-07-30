# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 這個 repo 是什麼

**`site-deploy` skill 本體的開發專案**——`~/.claude/skills/site-deploy/SKILL.md` 就是在這裡開發的。
repo root = skill root(`SKILL.md` 在專案根),沒有應用程式碼:交付物是 bash 腳本、專案模板與 markdown SOP。

> 本檔規範「如何開發這個 skill」;`templates/common/CLAUDE.md.tmpl` 是 scaffold 時**複製給客戶專案**的紀律檔,
> 兩者用途完全不同,改動前先確認自己要動的是哪一個。

### 已安裝的 skill 是另一份 clone,不是 symlink

`~/.claude/skills/site-deploy/` 與本 repo 都是 `https://github.com/kpn-shabu/site-deploy.git` 的獨立工作副本。
**在這裡改檔案,不會改變一次真正 `/site-deploy` 執行的行為。** 同步方式:

```bash
git push                                              # 本 repo → GitHub
git -C ~/.claude/skills/site-deploy pull              # 安裝副本取回(README 的正式路徑)
# 快速迭代也可直接從本地拉(不經 GitHub):
git -C ~/.claude/skills/site-deploy pull /path/to/this/repo main
```

要推論「使用者實際跑到的 skill 是哪一版」時,先比對:
`git -C ~/.claude/skills/site-deploy log --oneline -1` 對上本 repo HEAD。

git 身分為 repo-local `ShabuWu <shabu@kpnweb.com>`;remote 走 HTTPS + `credential.helper=!gh auth git-credential`
(這台機器的 SSH 金鑰屬 GitHub 帳號 `buburian`,對 `kpn-shabu` 的 repo 走 SSH 會被拒,別改成 SSH remote)。

## 驗證方式(沒有 build / lint / test 工具鏈)

- 靜態:`bash -n scripts/*.sh`(目前全過)。`shellcheck` 未安裝,要用得先 `brew install shellcheck`。
- 實測:**腳本無法在本 repo 執行**。它們一律從「被 scaffold 出來的客戶專案根」執行、開頭 `source deploy/deploy.conf`,
  在這裡跑只會得到「找不到 deploy/deploy.conf」而中止——那是正常行為,不是 bug。
  真正的驗證是照 SKILL.md Phase 0 scaffold 一個拋棄式專案,再於該專案跑 `scripts/smoke-test.sh local`
  (`ef3bfb0` 的 php stack 冒煙測試就是這樣做的:build / healthcheck / smoke-routes / DB 連線 / reload-php 全綠)。
- 流程圖 `skill-flow.drawio(.png)`:流程有結構性變動時用 `drawio-skill` 重新產生,PNG 需內嵌 XML。

## 架構:三層 + 一份契約

| 層 | 檔案 | 職責 |
|---|---|---|
| 判斷 | `SKILL.md` | 階段推導、生命週期、守則、技術陷阱——交給 LLM 執行的部分 |
| 機械 | `scripts/*.sh` | 必須精確、不容 LLM 即興發揮的步驟(deploy / rollback / provision / smoke-test) |
| 素材 | `templates/`、`references/` | scaffold 的檔案來源、各 stack 與 provision 的細節 |

**`SKILL-SPEC.md` 是規格書,§8「實作契約」是所有 templates / scripts / references 的硬性共用約定**
(compose service/volume 命名、`/srv/<site>` 容器內外同路徑、`src/` 程式根、`deploy.conf` 的 key、
`.deploy-meta` 格式、symlink 切換寫法、smoke-test exit code 0/1/2 的意義)。
改動任何一處前先讀 §8;若改動使契約失效,**同時更新 SPEC**,別讓 SPEC 與實作各說各話。
§0 的前提與 §4 的階段設計已定案,不要在 CLAUDE.md 重述、也不要擅自推翻。

### 一個改動的漣漪範圍

這個 repo 的難處是同一條不變量散落在多個檔案,改一處就要掃過全部:

- **php 系的 uid(alpine 的 `www-data` = 82,不是 Debian 的 33)**:
  `templates/php|laravel/Dockerfile` → `deploy.conf` 的 `WRITABLE_DIRS` 語意 → `scripts/deploy.sh` 的 chown →
  `SKILL.md` 技術陷阱 #3 → SPEC §8。
- **`deploy.conf` 新增或改名一個 key**:`templates/common/deploy.conf.example` → 四支腳本的 `: "${KEY:?}"` 檢查 →
  SKILL.md Phase 0 的填寫指示 → SPEC §8 的 keys 清單。
- **本機 port**:`templates/<stack>/compose.override.yml` 的 ports 必須與 `deploy.conf` 的 `APP_PORT_LOCAL` 同步,
  `smoke-test.sh local` 直接拿後者組 URL。
- **smoke-test.sh 的 exit code**:`deploy.sh` 依 `2 = 憑證/TLS 可等待型失敗(不回滾)` 分流,改語意會靜默破壞回滾決策。

### 模板規則

- 佔位符**只有** `{{SITE}}` 與 `{{DOMAIN}}`,scaffold 時全域替換;其他參數一律進 `deploy/deploy.conf`。
- 每個 stack 目錄**自成一套完整檔案**,scaffold 只複製一個目錄,不做跨目錄組合(`ci4` 用 `templates/php/`)。
- 因此 `templates/php/` 與 `templates/laravel/` 是**各自獨立實作**,共享 SPEC §8 的契約但**並非逐字相同**
  (實測全部同名檔案都有差異:nginx 的 `user` 一為 `www-data` 一為 `nginx`、pid 路徑、`client_max_body_size`、
  Dockerfile 的擴充與套件清單都不同)。動到共用不變量時**兩邊都要改**,但不要直接把一邊覆蓋過去。

### 部署模型(讀腳本前先有這張圖)

遠端 `/srv/<site>/` = `releases/<ts>/` + `current` symlink + `shared/`(`.env`、`uploads`)。
bind mount 在容器啟動時解析 symlink,所以整層 `/srv/<site>` 以**容器內外同路徑**掛載,
nginx root 指 `current/src/public`,切 symlink 才即時生效;部署指令一律 `run --rm -w <新 release>` 的一次性容器,
不 `exec` 進運行中的 app。細節與其餘六條「絕不可違反」的陷阱見 `SKILL.md`。

## 守則

- **Phase 5 backup 是刻意的佔位**(使用者明示另案討論),除非使用者開口,不要把備份 SOP 補完。
- 全部文件、註解、輸出訊息一律**繁體中文**;腳本一律 `set -euo pipefail`、從專案根執行、開頭 `source deploy/deploy.conf`。
- 這個 skill 設 `disable-model-invocation: true`,只由使用者 `/site-deploy` 觸發,且觸發後必須先報告現況、
  取得同意才動作——改 SKILL.md 時不要弱化這個把關。
