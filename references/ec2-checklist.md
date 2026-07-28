# EC2 開機 checklist(人工步驟,自動化從「SSH 連得上」開始)

原則:**一台 EC2 一個站**。以下在 AWS Console(EC2 → Launch instance)逐項完成;
全部做完、最後一條驗收通過,才輪到 `/site-deploy` 的 Phase 2(provision)。

## Launch instance

- [ ] **Region**:選離目標訪客近的區(台灣客戶常用 ap-northeast-1 東京)。
- [ ] **Name**:填站名,方便日後辨識。
- [ ] **AMI**:Ubuntu Server **24.04 LTS**(Noble Numbat),64-bit **x86_64**。
- [ ] **機型**:**t3.small 起跳**(2 vCPU / 2G RAM)。
      Node/Next.js 站建議 **t3.medium**(4G RAM),或至少確保 provision 會加
      2G swap(skill 預設會加)——`next build` 在 2G RAM 無 swap 下會 OOM。
- [ ] **金鑰對(Key pair)**:建立新的(或選既有),下載 `.pem` 後:
      移到 `~/.ssh/`,`chmod 400 ~/.ssh/<檔名>.pem`。**遺失不可補發**,只能換 key。
- [ ] **磁碟**:gp3,**20GB 以上**(image、releases×5、pgdata、log 都吃空間)。

## Security Group(inbound 只開三個 port)

- [ ] `22`(SSH)——Source 建議選 **My IP** 限制來源;IP 會變的話再放寬。
- [ ] `80`(HTTP)——Source `0.0.0.0/0`(Caddy ACME 驗證與轉址需要)。
- [ ] `443`(HTTPS)——Source `0.0.0.0/0`。
- [ ] 除此之外**不開任何 port**(postgres 不對外;app 走 Caddy 反代)。

## Elastic IP(必做)

- [ ] EC2 → Elastic IPs → **Allocate**,然後 **Associate** 到剛開的 instance。
      沒有 Elastic IP,stop/start 後公網 IP 會變,DNS A 記錄跟著失效。
- [ ] 記下這個 IP:Phase 3(dns-gate)設 A 記錄用的就是它。

## 本機 ~/.ssh/config 加 host alias

在 `~/.ssh/config` 加一段(`acme` 換成你的站名、IP 與 pem 檔名換成實際值):

```
Host acme-prod
    HostName <Elastic IP>
    User ubuntu
    IdentityFile ~/.ssh/acme-prod.pem
```

- [ ] 這個 alias(如 `acme-prod`)就是之後 `deploy/deploy.conf` 裡的 `SSH_HOST`。

## 驗收(唯一完成條件)

- [ ] 本機執行 `ssh <alias>`(如 `ssh acme-prod`)——**不加任何額外參數**
      就能登入到 ubuntu@ 提示符,即完成。
      之後的一切(裝 docker、swap、目錄、.env…)交給 provision.sh,人不用再上去動手。

連不上的常見原因:SG 的 22 限了來源但你的 IP 變了;pem 權限不是 400;
`User` 不是 ubuntu;Elastic IP 還沒 associate。
