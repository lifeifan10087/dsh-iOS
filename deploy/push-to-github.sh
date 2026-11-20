#!/usr/bin/env bash
# 一键：初始化仓库 → 提交 → 推到 GitHub → 触发 Actions 编译
# 用法: GITHUB_TOKEN=ghp_xxx bash deploy/push-to-github.sh <owner>/<repo>
set -euo pipefail
REPO="${1:?用法: push-to-github.sh <owner>/<repo>}"
TOKEN="${GITHUB_TOKEN:?先 export GITHUB_TOKEN=你的 PAT（repo + workflow 权限）}"
KIT="$(cd "$(dirname "$0")/.." && pwd)"
NODE_VER="${NODE_VER:-v24.9.0}"; MIN_IOS="${MIN_IOS:-14.0}"

cd "$KIT"
if [ ! -d .git ]; then git init -q; fi
git add -A
git -c user.name=dsh-port -c user.email=dsh@local commit -qm "dsh-go iOS port kit" 2>/dev/null || echo "没有新改动，跳过提交"
git branch -M main
git remote remove origin 2>/dev/null || true
git remote add origin "https://x-access-token:${TOKEN}@github.com/${REPO}.git"
git push -u origin main

echo "== 触发 Actions"
GITHUB_TOKEN="$TOKEN" REPO="$REPO" NODE_VER="$NODE_VER" MIN_IOS="$MIN_IOS" node -e '
const {GITHUB_TOKEN,T,REPO,NODE_VER,MIN_IOS}={...process.env,REPO:process.env.REPO};
fetch(`https://api.github.com/repos/${REPO}/actions/workflows/build-node-ios.yml/dispatches`,{
  method:"POST",
  headers:{authorization:`Bearer ${GITHUB_TOKEN}`,accept:"application/vnd.github+json","content-type":"application/json"},
  body:JSON.stringify({ref:"main",inputs:{node_version:NODE_VER,min_ios:MIN_IOS}})
}).then(async r=>{console.log("dispatch:",r.status,r.status===204?"已开始":"看返回");
  if(r.status!==204) console.log((await r.text()).slice(0,300));
}).catch(e=>console.log("触发失败:",e.message));
'
echo "进度: https://github.com/${REPO}/actions"
echo "编好后拉产物: GITHUB_TOKEN=$TOKEN node deploy/fetch-artifact.mjs $REPO"
