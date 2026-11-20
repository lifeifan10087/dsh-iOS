"use strict";
/**
 * node-addon-require-builtin 的纯 JS 替身。
 * 用途：iOS / 任意没有该原生 addon 的平台，让 dsh 能加载 Node 内部 ESM/CJS loader。
 * 前提：Node 必须以 --expose-internals 启动（release 版也支持该 flag）。
 */
Object.defineProperty(exports, "__esModule", { value: true });
const { createRequire } = require("node:module");

const req = createRequire(__filename);
const cache = new Map();

function requireBuiltin(id) {
	if (cache.has(id)) return cache.get(id);
	try {
		const mod = req(id);
		cache.set(id, mod);
		return mod;
	} catch (e) {
		const err = new Error(
			`requireBuiltin(${id}) 不可用（${e.code || e.message}）。请用 node --expose-internals 启动。`,
		);
		err.cause = e;
		throw err;
	}
}

function isAllowedInternalId(id) {
	return typeof id === "string" && id.startsWith("internal/");
}

function getBindingInfo() {
	return { mode: "js", product: "require-builtin", backend: "expose-internals", exposed: true };
}

exports.requireBuiltin = requireBuiltin;
exports.isAllowedInternalId = isAllowedInternalId;
exports.getBindingInfo = getBindingInfo;
exports.default = { requireBuiltin, isAllowedInternalId, getBindingInfo };
