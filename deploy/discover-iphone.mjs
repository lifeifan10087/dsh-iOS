#!/usr/bin/env node
// 在局域网里找 iPhone：mDNS 查询 _ssh._tcp / _apple-mobdev2._tcp + 端口探测
// 用法: node deploy/discover-iphone.mjs [网段，如 192.168.10]
import dgram from "node:dgram";
import net from "node:net";

const subnet = process.argv[2] || "192.168.10";

// --- mDNS ---
const query = (name) => {
  const q = Buffer.alloc(12);
  q.writeUInt16BE(0, 0); q.writeUInt16BE(0, 2); q.writeUInt16BE(1, 4);
  q.writeUInt16BE(0, 6); q.writeUInt16BE(0, 8); q.writeUInt16BE(0, 10);
  const parts = name.split(".").filter(Boolean);
  const bufs = [q];
  for (const p of parts) {
    bufs.push(Buffer.from([p.length]), Buffer.from(p));
  }
  bufs.push(Buffer.from([0, 0, 12, 0, 1])); // PTR, IN
  return Buffer.concat(bufs);
};

const mdns = await new Promise((resolve) => {
  const found = new Set();
  const sock = dgram.createSocket("udp4");
  sock.on("message", (msg, rinfo) => {
    const text = msg.toString("latin1");
    if (/ssh|apple|iphone/i.test(text)) found.add(rinfo.address);
  });
  sock.bind(() => {
    try { sock.setBroadcast(true); } catch {}
    for (const n of ["_ssh._tcp.local", "_apple-mobdev2._tcp.local", "_device-info._tcp.local"]) {
      sock.send(query(n), 5353, "224.0.0.251");
    }
  });
  setTimeout(() => { sock.close(); resolve([...found]); }, 4000);
});
console.log("mDNS 响应主机:", mdns.length ? mdns.join(", ") : "无");

// --- 端口探测 ---
const probe = (ip, port) => new Promise((res) => {
  const s = new net.Socket();
  const done = (ok) => { s.destroy(); res(ok ? `${ip}:${port}` : null); };
  s.setTimeout(700);
  s.once("connect", () => done(true));
  s.once("timeout", () => done(false));
  s.once("error", () => done(false));
  s.connect(port, ip);
});
const ips = Array.from({ length: 254 }, (_, i) => `${subnet}.${i + 1}`);
const hits = [];
for (let i = 0; i < ips.length; i += 60) {
  const batch = await Promise.all(ips.slice(i, i + 60).flatMap((ip) => [22, 2222].map((p) => probe(ip, p))));
  hits.push(...batch.filter(Boolean));
}
console.log("SSH 端口:", hits.length ? hits.join(", ") : "没有开放的主机");
if (hits.length) console.log(`试: SSHPASS=alpine DEVICE=root@${hits[0].split(":")[0]} bash deploy/install-ios.sh out/node-ios-patched`);
