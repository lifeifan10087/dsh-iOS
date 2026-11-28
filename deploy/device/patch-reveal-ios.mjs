import { readFileSync, writeFileSync, existsSync, copyFileSync } from "node:fs";
const F = "/var/mobile/Library/dsh/app/node_modules/@deepseek-ai/dsh-native-command/lib/index.js";
const BAK = F + ".debpatch.bak";
if (existsSync(BAK)) { copyFileSync(BAK, F); console.log("已从备份还原"); }
let src = readFileSync(F, "utf8");
const MARK = "IOS_FILE_SHARE_BRANCH";
const BRANCH = [
  "\t// " + MARK + ": iOS 没有 macOS 的 open -R，改为「文件」App 深链；",
  "\t// 工作区文件先复制进宿主 App 容器（文件 App 可见）再跳过去。",
  '\tconst fsProbe = await import("node:fs");',
  '\tif ((process.platform === "darwin" || process.platform === "ios") && fsProbe.existsSync("/var/jb")) {',
  '\t\tconst pathm = await import("node:path");',
  '\t\tconst cpm = await import("node:child_process");',
  '\t\tconst { promisify } = await import("node:util");',
  "\t\tconst runFile = promisify(cpm.execFile);",
  "\t\tconst shareRoots = [];",
  '\t\ttry {',
  '\t\t\tfor (const name of fsProbe.readdirSync("/var/mobile/Containers/Data/Application")) {',
  '\t\t\t\tconst dir = "/var/mobile/Containers/Data/Application/" + name;',
  "\t\t\t\ttry {",
  '\t\t\t\t\tconst meta = fsProbe.readFileSync(dir + "/.com.apple.mobile_container_manager.metadata.plist").toString("latin1");',
  '\t\t\t\t\tif (meta.includes("com.dsh.go.shell")) shareRoots.push(dir + "/Documents");',
  "\t\t\t\t} catch {}",
  "\t\t\t}",
  "\t\t} catch {}",
  "\t\tconst share = shareRoots[0];",
  "\t\tlet target = pathm.dirname(path);",
  "\t\tif (share !== undefined) {",
  '\t\t\tif (!path.startsWith(share + "/")) {',
  "\t\t\t\ttry {",
  "\t\t\t\t\tconst dest = share + \"/\" + pathm.basename(path);",
  "\t\t\t\t\tfsProbe.copyFileSync(path, dest);",
  "\t\t\t\t\ttry { fsProbe.chownSync(dest, 501, 501); fsProbe.chmodSync(dest, 0o644); } catch {}",
  "\t\t\t\t} catch {}",
  "\t\t\t\ttarget = share;",
  "\t\t\t}",
  "\t\t}",
  '\t\ttry { await runFile("/var/jb/usr/bin/uiopen", ["shareddocuments://private" + target]); } catch {}',
  "\t\treturn;",
  "\t}",
  "",
].join("\n");
const re = /(async function revealNativePath\(path, signal, internals = \{\}\) \{\r?\n\tsignal\.throwIfAborted\(\);)/;
if (!re.test(src)) { console.log("pattern not found"); process.exit(1); }
copyFileSync(F, BAK);
writeFileSync(F, src.replace(re, "$1\n" + BRANCH));
console.log("patched (clean)");
