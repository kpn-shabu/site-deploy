# {{SITE}} 的 node runtime image:只燒核心,不 COPY 程式碼。
# 主程式一律由 compose bind mount 掛入(本機掛專案根 → current,遠端掛整層 /srv/{{SITE}}),
# 換版靠切 current symlink + 重啟容器;image 無需重建,除非 docker/ 本身有變更。
FROM node:22-slim

# 以非 root 執行:官方 image 內建 node 使用者(uid 1000),
# 與 EC2 上的 ubuntu(uid 1000)相同,release 目錄與 uploads 免額外 chown
USER node

# 程式根一律 src/(package.json 在 src/ 下);
# 目錄實體由 bind mount 提供,這裡只是把預設工作目錄對準它
WORKDIR /srv/{{SITE}}/current/src

# 不設 CMD:啟動指令由 compose 提供(prod:npm run start;本機 override:npm run dev)
