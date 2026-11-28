#!/var/jb/bin/sh
# smoke-test.sh —— 装完/重启后自检「能不能真的对话」，失败自动回退
#
# 背景：boot-start 里曾经加过 `--profile web --patch <file>` 作为绕过手段，
# 那会让 profile 组合失效 —— 界面照样打开，但模型列表/历史/回合全静默失效。
# 这里把它做成可执行的自检：发现 --patch 就清掉，跑一轮最小对话验证。
#
# 用法：smoke-test.sh [--fix]     --fix 表示失败时自动改写 boot-start 并重启
set -u
H=/var/mobile/Library/dsh
NODE=/var/jb/usr/local/lib/dsh/node
PRE=$H/shim/ios-preload.cjs
LOG=$H/smoke-test.log
FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

say() { echo "$@" | tee -a "$LOG"; }
: > "$LOG"
say "=== smoke test $(date) ==="

fail=0
# 1) 基础前提
[ -e /var/jb/bin/sh ] || { ln -sfn /var/jb/usr/bin/dash /var/jb/bin/sh; say "FIX  /var/jb/bin/sh 链接已补"; }
grep -q 'export DSH_HOME' "$H/boot-start.sh" 2>/dev/null || { say "FAIL boot-start 缺 DSH_HOME"; fail=1; }
grep -q 'var/jb/usr/bin' "$H/boot-start.sh" 2>/dev/null || { say "FAIL boot-start 缺 PATH"; fail=1; }
if grep -v '^[[:space:]]*#' "$H/boot-start.sh" 2>/dev/null | grep -q -- '--patch'; then
  say "WARN boot-start 仍在用 --patch（会破坏 profile 组合）"
  if [ "$FIX" = 1 ]; then
    sed -i '' 's/ --profile web \$PATCHARG//' "$H/boot-start.sh" 2>/dev/null || \
      sed -i 's/ --profile web \$PATCHARG//' "$H/boot-start.sh"
    sed -i '' 's/ --patch [^ ]*//g' "$H/boot-start.sh" 2>/dev/null || \
      sed -i 's/ --patch [^ ]*//g' "$H/boot-start.sh"
    say "FIX  已从 boot-start 去掉 --patch，重启引擎"
    for p in $(ps -A -o pid,args 2>/dev/null | grep "[u]sr/local/lib/dsh/node" | sed 's/^ *//' | cut -d' ' -f1); do kill -9 "$p" 2>/dev/null; done
    rm -f "$H/engine.pid"; sleep 2
    sh "$H/boot-start.sh" >/dev/null 2>&1; sleep 26
  fi
fi

# 2) 引擎 / 代理 / 插件
U=$(cat "$H/.web-url" 2>/dev/null)
[ -n "$U" ] || { say "FAIL .web-url 为空"; fail=1; }
"$NODE" --jitless --require "$PRE" -e '
const fs=require("fs");
(async()=>{
  const u=fs.readFileSync("/var/mobile/Library/dsh/.web-url","utf8").trim();
  const r0=await fetch(u,{redirect:"manual"});
  const c=(r0.headers.get("set-cookie")||"").split(";")[0];
  const home=await fetch("http://127.0.0.1:3080/",{headers:{cookie:c}});
  const html=await home.text();
  const rt=await fetch("http://127.0.0.1:3080/redteam/api",{headers:{cookie:c}});
  let proxy="down";
  try { const p=await fetch("http://127.0.0.1:3081/",{redirect:"manual"}); proxy=p.status; } catch(e){}
  console.log(`web=${home.status} purge=${rt.status} purgeInHtml=${html.includes("purge")} proxy=${proxy}`);
})()' 2>/dev/null | grep -v Warning | while read line; do say "CHECK $line"; done

# 3) 真跑一轮最小对话（ACP）——这是唯一能证明“能对话”的方式
# 回合需要模型凭证：env.sh 里有 DEEPSEEK_API_KEY（600），必须先加载
. "$H/env.sh" 2>/dev/null || true
export DEEPSEEK_API_KEY DSH_PERMISSION_MODE DSH_HOME
say "TURN  跑一轮最小对话…"
cat > /var/mobile/Library/dsh/tmp/smoke-turn.mjs <<'JS'
import { spawn } from "node:child_process";
const child = spawn(process.execPath, ["--jitless","--expose-internals","--experimental-sqlite",
  "--require","/var/mobile/Library/dsh/shim/ios-preload.cjs",
  "/var/mobile/Library/dsh/app/node_modules/@deepseek-ai/dsh/lib/bin.js","--profile","acp"],
  { stdio:["pipe","pipe","pipe"] });
let buf="", id=0; const pending=new Map();
child.stdout.on("data",(d)=>{buf+=d.toString();let i;while((i=buf.indexOf("\n"))>=0){const l=buf.slice(0,i);buf=buf.slice(i+1);if(!l.trim())continue;let m;try{m=JSON.parse(l)}catch{continue}if(m.id&&pending.has(m.id)){pending.get(m.id)(m);pending.delete(m.id)}}});
const call=(m,p)=>new Promise((res)=>{const mid=++id;pending.set(mid,res);child.stdin.write(JSON.stringify({jsonrpc:"2.0",id:mid,method:m,params:p})+"\n");setTimeout(()=>res({timeout:true}),70000)});
await call("initialize",{protocolVersion:"2025-01-01",clientCapabilities:{}});
const s=await call("session/new",{cwd:"/var/mobile/Documents",mcpServers:[]});
const t0=Date.now();
const r=await call("session/prompt",{sessionId:s.result?.sessionId,prompt:[{type:"text",text:"只回两个字：好的"}]});
const ok = r && !r.timeout && r.result && r.result.stopReason;
console.log(ok ? `TURN_OK ${((Date.now()-t0)/1000).toFixed(1)}s stop=${r.result.stopReason}` : "TURN_FAIL " + JSON.stringify(r).slice(0,120));
child.kill("SIGKILL");
JS
TURN=$($NODE --jitless --require "$PRE" /var/mobile/Library/dsh/tmp/smoke-turn.mjs 2>/dev/null | grep -E "TURN_(OK|FAIL)" | tail -1)
say "${TURN:-TURN_FAIL no-output}"
case "${TURN:-}" in TURN_OK*) ;; *) fail=1 ;; esac

if [ "$fail" = 0 ]; then say "=== RESULT PASS ==="; else say "=== RESULT FAIL ==="; fi
exit "$fail"
