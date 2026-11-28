import UIKit
import SwiftUI
import SafariServices

// DSH Go 原生客户端 v3 —— 最大程度仿 dsh-go
// 认证交给本地代理 127.0.0.1:3081；手机状态走 tweak 的 127.0.0.1:8090。

let kBase = URL(string: "http://127.0.0.1:3081")!
let kTweak = URL(string: "http://127.0.0.1:8090/mcp")!
let kWebFallback = URL(string: "http://127.0.0.1:3081/")!

// 主题（可切换，存 UserDefaults）
struct Theme {
    static let presets: [(String, Color)] = [
        ("黛青", Color(red: 0.10, green: 0.55, blue: 0.56)),
        ("雾蓝", Color(red: 0.35, green: 0.55, blue: 0.85)),
        ("暮紫", Color(red: 0.45, green: 0.38, blue: 0.78)),
        ("松石", Color(red: 0.15, green: 0.62, blue: 0.50)),
        ("琥珀", Color(red: 0.85, green: 0.58, blue: 0.15)),
        ("石墨", Color(red: 0.35, green: 0.35, blue: 0.38)),
    ]
}

func dshlog(_ msg: String) {
    let line = "[\(Int(Date().timeIntervalSince1970))] \(msg)\n"
    guard let d = line.data(using: .utf8) else { return }
    if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
        let u = docs.appendingPathComponent("dsh-app.log")
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        else { try? d.write(to: u) }
    }
}

// MARK: - RPC

struct RPCError: LocalizedError { let code: String; let message: String
    var errorDescription: String? { "\(code)：\(message)" } }

actor RPC {
    static let shared = RPC()
    private var seq = 0
    func call(_ method: String, args: [String: Any]) async throws -> [String: Any] {
        seq += 1
        let body: [String: Any] = ["type": "client-request", "rpcId": "ios-\(seq)-\(Int(Date().timeIntervalSince1970))",
                                   "method": method, "payload": ["args": args]]
        var req = URLRequest(url: kBase.appendingPathComponent("api/\(method)"))
        req.httpMethod = "POST"; req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw RPCError(code: "http", message: "状态码 \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            throw RPCError(code: "parse", message: String((String(data: data, encoding: .utf8) ?? "").prefix(100)))
        }
        if (result["ok"] as? Bool) == true { return (result["value"] as? [String: Any]) ?? [:] }
        let e = result["error"] as? [String: Any] ?? [:]
        throw RPCError(code: e["code"] as? String ?? "error", message: e["message"] as? String ?? "未知错误")
    }
    func ping() async -> Int {
        let t0 = Date(); var r = URLRequest(url: kBase); r.httpMethod = "HEAD"; r.timeoutInterval = 3
        _ = try? await URLSession.shared.data(for: r)
        return Int(Date().timeIntervalSince(t0) * 1000)
    }
    /// 通过 tweak 的 8090 拿 iPhone 前台应用（原生状态条用）
    func frontmostApp() async -> String? {
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                   "params": ["name": "get_frontmost_app", "arguments": [:]]]
        var req = URLRequest(url: kTweak); req.httpMethod = "POST"; req.timeoutInterval = 4
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? ""
        let line = text.split(separator: "\n").last(where: { $0.hasPrefix("{") }).map(String.init) ?? text
        guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        let res = j["result"] as? [String: Any]
        guard let content = (res?["content"] as? [[String: Any]])?.first,
              let raw = content["text"] as? String else { return nil }
        if let d = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
            return (d["name"] as? String) ?? (d["bundleId"] as? String)
        }
        return nil
    }
}

// MARK: - 模型

struct ChatItem: Identifiable, Equatable {
    enum Kind { case user, assistant, tool, info }
    let id: String
    var kind: Kind
    var text: String
    var name: String?
    var args: String?
    var result: String?
    var error: Bool = false
}

struct SessionRow: Identifiable, Equatable {
    let id: String
    var title: String
    var running: Bool
    var updatedAt: Date
}

// 把引擎塞在消息里的上下文包装裁掉，只留用户真正说的话
func stripContext(_ s: String) -> String {
    var t = s
    for marker in ["<project_instructions>", "<system_instructions>"] {
        if let r = t.range(of: marker, options: .backwards) { t = String(t[r.upperBound...]) }
    }
    // 去掉常见的上下文前缀段
    let noise = ["preparing turn", "Current runtime context.", "Browser time zone for this request",
                 "Elapsed since the preceding", "Current working directory", "Current DSH file policy",
                 "Approval requests are auto-granted"]
    let lines = t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var kept: [String] = []
    var skipping = false
    for line in lines {
        if noise.contains(where: { line.contains($0) }) { skipping = true; continue }
        if skipping && line.trimmingCharacters(in: .whitespaces).isEmpty { skipping = false; continue }
        if !skipping { kept.append(line) }
    }
    let out = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return out.isEmpty ? t.trimmingCharacters(in: .whitespacesAndNewlines) : out
}

// MARK: - Store

@MainActor
final class ChatStore: ObservableObject {
    @Published var sessions: [SessionRow] = []
    @Published var items: [ChatItem] = []
    @Published var sessionId = ""
    @Published var input = ""
    @Published var busy = false
    @Published var errorText: String?
    @Published var latency = 0
    @Published var frontApp: String = "—"
    @Published var drawOpen = false
    @Published var preset = "标准模式"
    @Published var accentIndex: Int {
        didSet { UserDefaults.standard.set(accentIndex, forKey: "dsh.accent") }
    }
    @Published var densityCompact: Bool {
        didSet { UserDefaults.standard.set(densityCompact, forKey: "dsh.density") }
    }

    private var poll: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var titleCache: [String: String] = [:]

    init() {
        accentIndex = UserDefaults.standard.object(forKey: "dsh.accent") as? Int ?? 0
        densityCompact = UserDefaults.standard.object(forKey: "dsh.density") as? Bool ?? true
    }

    var accent: Color { Theme.presets[min(accentIndex, Theme.presets.count - 1)].1 }

    func boot() async {
        await refreshSessions()
        latency = await RPC.shared.ping()
        if sessionId.isEmpty {
            if let f = sessions.first { await open(f.id) } else { await newChat() }
        }
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ms = await RPC.shared.ping()
                let app = await RPC.shared.frontmostApp()
                await MainActor.run { self.latency = ms; if let app { self.frontApp = app } }
                try? await Task.sleep(nanoseconds: 6_000_000_000)
            }
        }
    }

    func refreshSessions() async {
        do {
            let v = try await RPC.shared.call("session/list", args: ["_request": [:]])
            let arr = (v["items"] as? [[String: Any]]) ?? []
            sessions = arr.compactMap { o in
                guard let sid = o["sessionId"] as? String else { return nil }
                let ts = (o["updatedAt"] as? Double) ?? 0
                let title = titleCache[sid] ?? (o["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "新对话"
                return SessionRow(id: sid, title: title, running: (o["running"] as? Bool) ?? false,
                                  updatedAt: Date(timeIntervalSince1970: ts / 1000))
            }
            errorText = nil
        } catch { errorText = error.localizedDescription }
    }

    func newChat() async {
        do {
            let v = try await RPC.shared.call("session/create", args: ["request": [:]])
            if let sid = v["sessionId"] as? String {
                sessionId = sid; items = []; input = ""; errorText = nil
                if let p = v["agentPreset"] as? String, p.isEmpty == false { preset = p == "standard" ? "标准模式" : p }
                await refreshSessions()
            }
        } catch { errorText = error.localizedDescription }
    }

    func open(_ sid: String) async {
        sessionId = sid; items = []
        await load(); startPolling()
    }

    func load() async {
        guard !sessionId.isEmpty else { return }
        do {
            let v = try await RPC.shared.call("session/page", args: ["request": [
                "address": ["sessionId": sessionId, "kind": "session"], "maxMessages": 120]])
            let records = (v["records"] as? [[String: Any]]) ?? []
            items = Self.build(records)
            // 顺手记下标题
            for rec in records {
                if let e = rec["event"] as? [String: Any], (e["type"] as? String) == "session/title",
                   let d = e["data"] as? [String: Any], let t = d["title"] as? String, !t.isEmpty {
                    titleCache[sessionId] = t
                    if let i = sessions.firstIndex(where: { $0.id == sessionId }) { sessions[i].title = t }
                }
            }
            errorText = nil
        } catch { errorText = error.localizedDescription }
    }

    static func build(_ records: [[String: Any]]) -> [ChatItem] {
        var results: [String: (String, Bool)] = [:]
        for rec in records {
            guard let e = rec["event"] as? [String: Any], (e["type"] as? String) == "tool/result",
                  let d = e["data"] as? [String: Any] else { continue }
            let msg = d["message"] as? [String: Any] ?? [:]
            let callId = (msg["toolCallId"] as? String) ?? ((msg["source"] as? [String: Any])?["callId"] as? String) ?? ""
            let text = ((msg["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
            let isErr = ((d["status"] as? String) ?? "") == "error"
            if !callId.isEmpty { results[callId] = (text, isErr) }
        }
        var out: [ChatItem] = []
        for (i, rec) in records.enumerated() {
            guard let e = rec["event"] as? [String: Any], let type = e["type"] as? String,
                  let d = e["data"] as? [String: Any] else { continue }
            let id = "\(type)-\(i)"
            switch type {
            case "user/message":
                let raw = ((d["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
                let t = stripContext(raw)
                if !t.isEmpty, !raw.contains("preparing turn") { out.append(ChatItem(id: id, kind: .user, text: t)) }
                else if !t.isEmpty, !t.contains("preparing turn") { out.append(ChatItem(id: id, kind: .user, text: t)) }
            case "assistant/message":
                let msg = d["message"] as? [String: Any] ?? [:]
                let t = ((msg["content"] as? [[String: Any]]) ?? [])
                    .compactMap { p in (p["type"] as? String) == "text" ? (p["text"] as? String) : nil }.joined()
                let trimmed = stripContext(t)
                if !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(ChatItem(id: id, kind: .assistant, text: trimmed))
                }
            case "tool/call":
                let callId = d["callId"] as? String ?? ""
                let r = results[callId]
                out.append(ChatItem(id: id, kind: .tool, text: "", name: d["name"] as? String ?? "tool",
                                    args: d["arguments"] as? String ?? "", result: r?.0, error: r?.1 ?? false))
            case "turn/end":
                let bad = ((d["status"] as? String) ?? "") == "error"
                out.append(ChatItem(id: id, kind: .info, text: bad ? "— 本轮出错 —" : "— 本轮结束 —", error: bad))
            default: break
            }
        }
        return out
    }

    func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sessionId.isEmpty else { return }
        input = ""; busy = true
        items.append(ChatItem(id: "local-\(UUID().uuidString)", kind: .user, text: text))
        do {
            _ = try await RPC.shared.call("session/prompt", args: ["request": [
                "requestId": UUID().uuidString, "sessionId": sessionId, "mode": "queue",
                "content": [["type": "text", "text": text]],
                "clientTimeZone": TimeZone.current.identifier]])
            startPolling()
        } catch { errorText = error.localizedDescription; busy = false }
    }

    func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            guard let self else { return }
            var quiet = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                var running = false
                if let v = try? await RPC.shared.call("session/state", args: ["request": ["sessionId": self.sessionId]]) {
                    running = (v["running"] as? Bool) ?? false
                }
                await self.load()
                await MainActor.run { self.busy = running }
                quiet = running ? 0 : quiet + 1
                if quiet >= 4 { break }
            }
        }
    }
}

// MARK: - 视图

struct ToolCard: View {
    let item: ChatItem
    @EnvironmentObject var store: ChatStore
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: item.error ? "exclamationmark.triangle.fill" : "wrench.and.screwdriver.fill")
                        .font(.caption2).foregroundColor(item.error ? .red : .secondary)
                    Text(item.name ?? "tool").font(.system(.caption, design: .monospaced)).bold()
                    Text((item.args ?? "").replacingOccurrences(of: "\n", with: " "))
                        .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2).foregroundColor(.secondary)
                }
                .padding(10).background(Color.secondary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    Text("参数").font(.caption2).foregroundColor(.secondary)
                    Text(item.args ?? "").font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    if let r = item.result, !r.isEmpty {
                        Text("结果").font(.caption2).foregroundColor(.secondary)
                        Text(String(r.prefix(4000))).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

struct Bubble: View {
    let item: ChatItem
    @EnvironmentObject var store: ChatStore
    var body: some View {
        switch item.kind {
        case .user:
            HStack { Spacer(minLength: 46)
                Text(item.text).padding(11).foregroundColor(.white)
                    .background(store.accent).clipShape(RoundedRectangle(cornerRadius: 14))
                    .contextMenu { Button { UIPasteboard.general.string = item.text } label: { Label("拷贝", systemImage: "doc.on.doc") } }
            }
        case .assistant:
            HStack { Text(item.text).padding(11)
                .background(Color.secondary.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 14))
                .contextMenu { Button { UIPasteboard.general.string = item.text } label: { Label("拷贝", systemImage: "doc.on.doc") } }
                Spacer(minLength: 46) }
        case .tool:
            ToolCard(item: item)
        case .info:
            Text(item.text).font(.caption2).foregroundColor(item.error ? .red : .secondary)
                .frame(maxWidth: .infinity)
        }
    }
}

struct Composer: View {
    @EnvironmentObject var store: ChatStore
    let chips: [(String, String)] = [
        ("自检", "跑 iPhone 的冒烟自检 smoke-test.sh，把 CHECK 与 TURN 结果贴出来"),
        ("操控测试", "在 iPhone 上跑 phone-functest.mjs，汇总通过率并列出失败项"),
        ("补丁对账", "跑 apply-patches.sh 看改动数（应为 0）"),
        ("引擎日志", "看 iPhone 引擎日志最后 20 行，只报异常和插件激活情况"),
    ]
    var body: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.0) { c in
                        Button { store.input = c.1 } label: {
                            Text(c.0).font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Color.secondary.opacity(0.12)).clipShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 12)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("发消息或创建任务…", text: $store.input, axis: .vertical)
                    .lineLimit(1...5).padding(9)
                    .background(Color.secondary.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 14))
                Button { Task { await store.send() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                        .foregroundColor(store.input.trimmingCharacters(in: .whitespaces).isEmpty ? .secondary : store.accent)
                }.disabled(store.input.trimmingCharacters(in: .whitespaces).isEmpty || store.busy)
            }.padding(.horizontal, 12)
            HStack(spacing: 8) {
                Label("\(store.latency)ms", systemImage: "bolt.horizontal.fill")
                Text("·")
                Text(store.frontApp).lineLimit(1)
                Spacer()
                Text(store.busy ? "生成中…" : "就绪")
                Text("·")
                Text("\(store.sessions.count) 会话")
            }
            .font(.caption2).foregroundColor(.secondary)
            .padding(.horizontal, 14).padding(.bottom, 4)
        }
        .padding(.top, 6).background(.bar)
    }
}

struct Drawer: View {
    @EnvironmentObject var store: ChatStore
    @State private var showSettings = false

    var groups: [(String, [SessionRow])] {
        let cal = Calendar.current
        let now = Date()
        var today: [SessionRow] = [], yst: [SessionRow] = [], earlier: [SessionRow] = []
        for s in store.sessions {
            if cal.isDateInToday(s.updatedAt) { today.append(s) }
            else if cal.isDateInYesterday(s.updatedAt) { yst.append(s) }
            else { earlier.append(s) }
        }
        return [("今天", today), ("昨天", yst), ("更早", earlier)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("会话").font(.headline)
                Spacer()
                Button { Task { await store.newChat(); store.drawOpen = false } } label: { Image(systemName: "square.and.pencil") }
                Button { store.drawOpen = false } label: { Image(systemName: "xmark") }.padding(.leading, 10)
            }.padding()
            List {
                ForEach(groups, id: \.0) { g in
                    Section(g.0) {
                        ForEach(g.1) { s in row(s) }
                    }
                }
                Section {
                    Button { showSettings = true } label: { Label("界面设置", systemImage: "paintpalette") }
                    Button { store.drawOpen = false } label: { Label("网页版（兜底）", systemImage: "safari") }
                }
            }.listStyle(.insetGrouped)
        }
        .frame(maxWidth: 310).background(.background)
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    func row(_ s: SessionRow) -> some View {
        Button {
            store.drawOpen = false
            Task { await store.open(s.id) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).lineLimit(1).font(.subheadline)
                    Text(s.id.prefix(14)).font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                if s.running { ProgressView().scaleEffect(0.6) }
                if s.id == store.sessionId { Image(systemName: "checkmark.circle.fill").foregroundColor(store.accent) }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("强调色") {
                    ForEach(Array(Theme.presets.enumerated()), id: \.offset) { i, p in
                        Button {
                            store.accentIndex = i
                        } label: {
                            HStack {
                                Circle().fill(p.1).frame(width: 18, height: 18)
                                Text(p.0)
                                Spacer()
                                if store.accentIndex == i { Image(systemName: "checkmark") }
                            }
                        }.foregroundColor(.primary)
                    }
                }
                Section("密度") {
                    Toggle("紧凑", isOn: $store.densityCompact)
                }
                Section("当前引擎") {
                    LabeledContent("延迟", value: "\(store.latency) ms")
                    LabeledContent("会话数", value: "\(store.sessions.count)")
                    LabeledContent("当前会话", value: String(store.sessionId.prefix(18)))
                }
            }
            .navigationTitle("界面设置")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}

struct RootView: View {
    @StateObject private var store = ChatStore()
    @State private var showWeb = false

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) { header; content; Composer() }
                .environmentObject(store)
            if store.drawOpen {
                Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { store.drawOpen = false }
                Drawer().environmentObject(store).transition(.move(edge: .leading))
            }
        }
        .animation(.snappy(duration: 0.2), value: store.drawOpen)
        .sheet(isPresented: $showWeb) { SafariView(url: kWebFallback) }
        .task { await store.boot() }
        .overlay(alignment: .top) {
            if let e = store.errorText {
                Text(e).font(.caption2).foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.red.opacity(0.9)).clipShape(Capsule())
                    .padding(.top, 6).onTapGesture { store.errorText = nil }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { store.drawOpen = true } label: { Image(systemName: "line.3.horizontal") }
            Spacer()
            VStack(spacing: 0) {
                Text(currentTitle).font(.headline).lineLimit(1)
            }
            Spacer()
            Button { Task { await store.newChat() } } label: { Image(systemName: "plus") }
            Menu {
                Button("刷新会话") { Task { await store.refreshSessions(); await store.load() } }
                Button("网页版") { showWeb = true }
                Button("拷贝当前会话 ID") { UIPasteboard.general.string = store.sessionId }
            } label: {
                HStack(spacing: 3) {
                    Text(store.preset).font(.caption)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.secondary.opacity(0.12)).clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var currentTitle: String {
        store.sessions.first(where: { $0.id == store.sessionId })?.title ?? "新对话"
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: store.densityCompact ? 8 : 14) {
                    if store.items.isEmpty { emptyState }
                    ForEach(store.items) { m in Bubble(item: m).environmentObject(store).id(m.id) }
                    if store.busy {
                        HStack(spacing: 6) { ProgressView().scaleEffect(0.7)
                            Text("生成中…").font(.caption).foregroundColor(.secondary) }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .onChange(of: store.items.count) { _, _ in
                if let last = store.items.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 30)
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundColor(store.accent)
                Text("探索未至之境").font(.title3).bold()
            }
            Text("点下方建议开始，或直接输入").font(.caption).foregroundColor(.secondary)
            VStack(spacing: 10) {
                card("iPhone 现在什么状态", "三端口 + 最近报错", "查一下 iPhone 的引擎/代理/tweak 三端口状态和最近引擎日志")
                card("跑一遍操控回归", "20 项手机操控能力实测", "在 iPhone 上跑 phone-functest.mjs，给我通过率和失败项")
                card("重装后补丁有没有丢", "验 apply-patches 幂等", "跑 apply-patches.sh 看改动数，并解释每一处改动意味着什么")
            }
            Spacer()
        }.frame(maxWidth: .infinity).padding(.horizontal, 16)
    }

    private func card(_ t: String, _ s: String, _ p: String) -> some View {
        Button { store.input = p } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(t).font(.subheadline).bold()
                Text(s).font(.caption2).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

// MARK: - 入口

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo s: UISceneSession, options o: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.rootViewController = UIHostingController(rootView: RootView())
        w.makeKeyAndVisible(); window = w
        dshlog("native v3 up")
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ a: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool { true }
    func application(_ app: UIApplication, configurationForConnecting s: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: "Default Configuration", sessionRole: s.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
