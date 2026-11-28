// 手机操控功能测试：走 root MCP（stdio），底层触控走 tweak 8090
import { spawn } from "node:child_process";
const SRV = "/var/jb/usr/local/lib/dsh/mcp/mcp-ios-server.mjs";
const child = spawn(process.execPath, ["--jitless","--require","/var/mobile/Library/dsh/shim/ios-preload.cjs",SRV], { stdio:["pipe","pipe","pipe"] });
let buf="", id=0; const pending=new Map();
child.stdout.on("data",(d)=>{buf+=d.toString();let i;while((i=buf.indexOf("\n"))>=0){const l=buf.slice(0,i);buf=buf.slice(i+1);if(!l.trim())continue;let m;try{m=JSON.parse(l)}catch{continue}if(m.id&&pending.has(m.id)){pending.get(m.id)(m);pending.delete(m.id)}}});
const rpc=(m,p)=>new Promise((res)=>{const mid=++id;pending.set(mid,res);child.stdin.write(JSON.stringify({jsonrpc:"2.0",id:mid,method:m,params:p})+"\n");setTimeout(()=>res({timeout:true}),45000)});
await rpc("initialize",{protocolVersion:"2024-11-05",capabilities:{}});
const call=async(name,args={})=>{const t0=Date.now();const r=await rpc("tools/call",{name,arguments:args});const ms=Date.now()-t0;const text=r.result?.content?.[0]?.text??"";let ok=true,data=text;if(r.result?.isError)ok=false;try{data=JSON.parse(text)}catch{};return{ok,ms,data,text};};
const rows=[];
const T=async(label,name,args,check,detail)=>{
  const r=await call(name,args);
  let pass=r.ok;
  try{ if(pass && check) pass=!!check(r.data,r); }catch(e){ pass=false; }
  const d = detail ? detail(r.data, r) : String(r.text).replace(/\s+/g," ").slice(0,70);
  rows.push({label,pass,ms:r.ms,detail:d});
  console.log(`${pass?"PASS":"FAIL"}  ${label.padEnd(22)} ${String(r.ms+"ms").padStart(6)}  ${d}`);
  return r;
};
await T("device_state","device_state",{},d=>typeof d.locked!=="undefined"||typeof d.screen_on!=="undefined",d=>`locked=${d.locked} screen_on=${d.screen_on}`);
await T("ocr","ocr",{},d=>d.count>5,d=>`${d.count} 条文本`);
await T("launch_app(Settings)","launch_app",{bundle_id:"com.apple.Preferences"},d=>d.ok===true,d=>`frontmost=${d.frontmost}`);
await new Promise(r=>setTimeout(r,2000));
// 退回设置根页：连续点左上角返回，直到 OCR 里出现「无线局域网」
for (let i=0;i<4;i++) {
  const o = await call("ocr");
  const txt = String(o.data.items?.map(x=>x.text).join(" ")||"");
  if (txt.includes("无线局域网")) break;
  await call("tweak_call",{name:"tap_screen",arguments:{x:22,y:70}});
  await new Promise(r=>setTimeout(r,900));
}
const rootOcr = await call("ocr");
rows.push({label:"回到设置根页",pass:String(rootOcr.data.items?.map(x=>x.text).join(" ")).includes("无线局域网"),ms:rootOcr.ms,detail:"含无线局域网="+String(rootOcr.data.items?.map(x=>x.text).join(" ")).includes("无线局域网")});
console.log(`${rows.at(-1).pass?"PASS":"FAIL"}  ${"回到设置根页".padEnd(22)} ${String(rootOcr.ms+"ms").padStart(6)}  ${rows.at(-1).detail}`);
await T("Settings 已就绪","ocr",{},d=>String(d.items?.map(i=>i.text).join("")).includes("设置"),d=>`${d.count} 条, 含"设置"=${String(d.items?.map(i=>i.text).join("")).includes("设置")}`);
await T("tap_text(无线局域网)","tap_text",{text:"无线局域网",exact:true},d=>d.tapped===true&&d.screenChanged===true,d=>`(${d.point?.x},${d.point?.y}) screenChanged=${d.screenChanged} top=${d.topTextAfterTap}`);
await new Promise(r=>setTimeout(r,800));
await T("screenshot_file","screenshot_file",{},d=>d.bytes>1000,d=>`${(d.bytes/1024|0)}KB ${String(d.path).split("/").pop()}`);
await T("run_command(root)","run_command",{command:"id -un; echo rc=$?"},d=>String(d.stdout).includes("root"),d=>String(d.stdout).trim().split("\n")[0]);
await T("write_file","write_file",{path:"/var/mobile/Documents/dsh-test/functest.txt",content:"phone-test\n"},d=>d.size===11,d=>`${d.size}B`);
await T("read_file","read_file",{path:"/var/mobile/Documents/dsh-test/functest.txt"},d=>String(d.text).includes("phone-test"),d=>JSON.stringify(String(d.text).trim()));
await T("list_dir","list_dir",{path:"/var/mobile/Documents/dsh-test"},d=>Array.isArray(d.entries)&&d.entries.length>0,d=>`${d.entries?.length} 项`);
await T("clipboard_set","clipboard_set",{text:"dsh-phone-test-2026"},d=>true,()=>"写入 dsh-phone-test-2026");
await T("clipboard_get","clipboard_get",{},d=>String(d.text).includes("dsh-phone-test-2026"),d=>String(d.text).match(/dsh-phone-test-\d+/)?.[0]||"?");
await T("tail_syslog","tail_syslog",{seconds:1,max_lines:5},d=>d.bytes>0,d=>`${d.bytes}B`);
await T("open_url_verified","open_url_verified",{url:"prefs:root=Bluetooth"},d=>d.verified===true,d=>`${d.note} (screenChanged=${d.screenChanged})`);
await T("list_apps","list_apps",{query:"NewTerm"},d=>d.count>=1&&String(d.apps?.[0]?.bundleId).includes("."),d=>`${d.apps?.[0]?.name}=${d.apps?.[0]?.bundleId}`);
await T("list_running_apps","list_running_apps",{},d=>d.count>0&&d.apps.every(a=>String(a.bundleId).includes(".")),d=>`${d.count} 个应用`);
await T("frontmost_app","frontmost_app",{},d=>!!d.bundleId,d=>`${d.bundleId}`);
await T("press_key_retry","press_key_retry",{key:"delete",times:2},d=>d.attempts>=2,d=>`${d.attempts} 次尝试`);
await T("tweak_tools","tweak_tools",{},d=>Array.isArray(d)&&d.length>30,d=>`${d.length} 个 tweak 工具`);
const pass=rows.filter(r=>r.pass).length;
console.log(`\n== 汇总: ${pass}/${rows.length} 通过 ==`);
child.kill("SIGKILL");
