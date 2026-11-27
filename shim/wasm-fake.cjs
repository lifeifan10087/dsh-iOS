// wasm-fake.cjs —— `--jitless` 下让 undici 能加载的 WebAssembly 占位
//
// 为什么需要：
//   越狱 iOS 上 node 只能用 --jitless（否则 V8 JIT 分配代码页时 SIGBUS）。
//   但 --jitless 会让 V8 把 WebAssembly 整个关掉，而 Node 自带的 undici
//   （fetch / Headers / node:http 的 WebSocket 都指向它）在**模块加载期**就执行
//   `await WebAssembly.compile(llhttpWasmData)`，于是：
//       ReferenceError: WebAssembly is not defined
//       dsh: fatal load failure
//
//   这个占位让"加载"这一步通过（compile 返回一个假模块），代价是 undici 的
//   HTTP/1.1 解析器不能用 —— 出站请求需要另外的 fetch 实现（见 HANDOFF 待办）。
//
// 用法（必须用 --require 预载，且排在 dsh 之前）：
//   node --jitless --require /var/mobile/Library/dsh/wasm-fake.cjs \
//        --experimental-sqlite .../dsh/lib/bin.js web --host 127.0.0.1 --port 3080

const fakeModule = { __dshFakeWasm: true };

class FakeInstance {
  constructor() {
    // 假装有 llhttp 的导出符号；调用时会返回 0（解析不了，但不会崩）
    this.exports = new Proxy({}, { get: () => () => 0 });
  }
}

const WebAssemblyShim = {
  compile: () => Promise.resolve(fakeModule),
  compileStreaming: () => Promise.resolve(fakeModule),
  instantiate: () => Promise.resolve(new FakeInstance()),
  validate: () => true,
  Module: class {},
  Instance: FakeInstance,
  Memory: class {},
  Table: class {},
  Global: class {},
  RuntimeError: Error,
};

if (typeof globalThis.WebAssembly === "undefined") {
  Object.defineProperty(globalThis, "WebAssembly", {
    value: WebAssemblyShim,
    writable: true,
    configurable: true,
  });
}
