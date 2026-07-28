# {{SITE}} 的 node runtime image:只燒核心,不 COPY 程式碼。
# 主程式一律由 compose bind mount 掛入(本機掛專案根 → current,遠端掛整層 /srv/{{SITE}}),
# 換版靠切 current symlink + 重啟容器;image 無需重建,除非 docker/ 本身有變更。
FROM node:22-slim

# 程式根一律 src/(package.json 在 src/ 下);
# 目錄實體由 bind mount 提供,這裡只是把預設工作目錄對準它
WORKDIR /srv/{{SITE}}/current/src

# node_modules 由 compose 掛 named volume 蓋住。docker 初始化該 volume 時,
# 會沿用 image 內同路徑目錄的 owner/權限;image 內若沒有這個目錄,
# volume 會生成 root-owned,底下的 USER node 就寫不進去(npm install 報 EACCES)。
# 故必須在切 USER 前以 root 預建並歸給 node。
RUN mkdir -p node_modules && chown node:node node_modules

# 以非 root 執行:官方 image 內建 node 使用者(uid 1000),
# 與 EC2 上的 ubuntu(uid 1000)相同,release 目錄與 uploads 免額外 chown
USER node

# 不設 CMD:啟動指令由 compose 提供(prod:npm run start;本機 override:npm run dev)
