# site-deploy

Claude Code skill:客戶網站從本機 Docker 開發到 EC2 上線與維運的完整 SOP。

一台 EC2 一個站。image 只燒核心(php-fpm+nginx 或 node runtime),主程式 mount 在 host;
遠端外殼 Caddy 自動管 SSL(Let's Encrypt);PostgreSQL 存 named volume;排程一律 systemd timer。
支援 stack:純手寫 PHP、CodeIgniter 4、Laravel、Node.js(Next.js 等)。

## 安裝

```bash
git clone https://github.com/kpn-shabu/site-deploy.git ~/.claude/skills/site-deploy
```

## 使用

本 skill 設定為**僅限手動觸發**(`disable-model-invocation: true`),Claude 不會自動採用。
在 Claude Code 中輸入:

```
/site-deploy
```

觸發後 skill 會先讀取專案的 `deploy/state.json` 報告現況(開發期/維護期、即將執行的階段),
**經你同意後才開始執行**。

典型節奏:

1. `/site-deploy` → scaffold 新專案(會要求你命名專案)→ 進入開發期
2. 本機 Docker 開發,`scripts/smoke-test.sh local` 驗證
3. 說「要上線」→ provision EC2 → 設定 DNS A 記錄(人工)→ 首次部署 → 進入維護期
4. 之後每次改動:本機驗證 → 詢問後部署;需要時 `/site-deploy` 回滾

## 需求

- 本機:Docker、git、rsync、ssh(macOS/Linux)
- 遠端:一台可 SSH 的 Ubuntu 24.04 EC2(開機 checklist 見 `references/ec2-checklist.md`)
- DNS A 記錄由人工設定(skill 會產出指示並用 dig 驗證)

## 結構

```
SKILL.md          主 SOP(階段、守則、技術陷阱)
references/       各 stack 細節、provision、EC2 開機 checklist
templates/        php / laravel / node / common 專案模板
scripts/          deploy.sh、rollback.sh、provision.sh、smoke-test.sh
SKILL-SPEC.md     規格書(開發文件,含完整設計決策與實作契約)
```
