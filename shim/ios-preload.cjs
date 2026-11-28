// ios-preload.cjs —— 设备上 node 启动时统一预载：WebAssembly 占位 + fetch 替身
//
// 顺序很重要：先把 WebAssembly 占位装上，Node 内置 undici 在被“顺手”加载时
// （例如任何 ESM 文件 import "node:http"，会触发 node:http 的 WebSocket getter）
// 才不会因为 WebAssembly 未定义而炸掉；随后覆盖 globalThis.fetch 等，
// 让真正发出的请求走 shim/fetch-http.cjs（node:http/https 实现，不依赖 WASM）。
//
// 用法：
//   node --jitless --require /var/mobile/Library/dsh/ios-preload.cjs \
//        --expose-internals --experimental-sqlite .../dsh/lib/bin.js web ...
"use strict";

// 越狱 iOS 上的 node 报告 process.platform === "ios"，但 dsh 依赖的若干原生模块
// （@deepseek-ai/node-addon-system 的 flock 等）只认 linux/darwin，遇到 ios 直接抛
// ERR_FLOCK_UNSUPPORTED_PLATFORM，会话持久化就挂。这里统一谎报成 darwin/arm64：
// 我们已经把 darwin-arm64 那套原生 addon 的 LC_BUILD_VERSION 改成 iOS（platform=2）
// 并重签，所以按 darwin 解析出来的 addon 在设备上能正常加载。
Object.defineProperty(process, "platform", { value: "darwin", configurable: true });
Object.defineProperty(process, "arch", { value: "arm64", configurable: true });

// 光改 process.platform 不够：sharp 之类用 os.platform() 判定运行时，
// 会认成 ios-arm64 然后报 "Could not load the sharp module"。
// node:os 是内置模块，这里在它被首次 require 时再包一层（懒加载，避免过早拉模块）。
const Module = require("node:module");
const origLoad = Module._load;
Module._load = function (request, parent, isMain) {
  const mod = origLoad.call(this, request, parent, isMain);
  if (request === "node:os" || request === "os") {
    try {
      Object.defineProperty(mod, "platform", { value: () => "darwin", configurable: true });
      Object.defineProperty(mod, "type", { value: () => "Darwin", configurable: true });
    } catch {}
  }
  return mod;
};

require("./wasm-fake.cjs");

const { install } = require("./fetch-http.cjs");
install(globalThis);

// undici 的 npm 包在被 dsh-http-proxy 动态 import 时会实例化假 exports，
// 这里不拦；真正发请求都走上面装好的 fetch。
