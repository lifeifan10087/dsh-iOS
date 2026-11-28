import UIKit
import SwiftUI
import SafariServices

// DSH Go 原生客户端（v2：仿 dsh-go —— 抽屉、空状态建议、快捷胶囊、工具卡片、主题、流式轮询）
// 认证交给本地代理 127.0.0.1:3081（它自己换 cookie），客户端不碰 token。

let kBase = URL(string: "http://127.0.0.1:3081")!
let kWebFallback = URL(string: "http://127.0.0.1:3081/")!
let kAccent = Color(red: 0.10, green: 0.55, blue: 0.56)   // 黛青

func dshlog(_ msg: String) {
    let line = "[\(Int(Date().timeIntervalSince1970))] \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
        let url = docs.appendingPathComponent("dsh-app.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
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
        let err = result["error"] as? [String: Any] ?? [:]
        throw RPCError(code: err["code"] as? String ?? "error", message: err["message"] as? String ?? "未知错误")
    }
    func ping() async -> Int {
        let t0 = Date()
        var req = URLRequest(url: kBase); req.timeoutInterval = 3
        req.httpMethod = "HEAD"
        _ = try? await URLSession.shared.data(for: req)
        return Int(Date().timeIntervalSince(t0) * 1000)
    }
}

// MARK: - 模型

struct ChatItem: Identifiable, Equatable {
    enum Kind { case user, assistant, tool, info }
    let id: String
    var kind: Kind
    var text: String
    var name: String? = nil       // 工具名
    var args: String? = nil       // 工具参数
    var result: String? = nil     // 工具结果
}

struct SessionRow: Identifiable, Equatable {
    let id: String
    var title: String
    var running: Bool
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
    @Published var drawOpen = false

    private var poll: Task<Void, Never>?

    func boot() async {
        await refreshSessions()
        latency = await RPC.shared.ping()
        if sessionId.isEmpty {
            if let first = sessions.first { await open(first.id) }
            else { await newChat() }
        }
    }

    func refreshSessions() async {
        do {
            let v = try await RPC.shared.call("session/list", args: ["_request": [:]])
            let arr = (v["items"] as? [[String: Any]]) ?? []
            sessions = arr.compactMap { o in
                guard let sid = o["sessionId"] as? String else { return nil }
                let t = (o["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(sid.prefix(8))
                return SessionRow(id: sid, title: t, running: (o["running"] as? Bool) ?? false)
            }
            errorText = nil
        } catch { errorText = error.localizedDescription }
    }

    func newChat() async {
        do {
            let v = try await RPC.shared.call("session/create", args: ["request": [:]])
            if let sid = v["sessionId"] as? String {
                sessionId = sid; items = []; input = ""; errorText = nil
                await refreshSessions()
                return
            }
        } catch { errorText = error.localizedDescription }
    }

    func open(_ sid: String) async {
        sessionId = sid; items = []
        await load()
        startPolling()
    }

    func load() async {
        guard !sessionId.isEmpty else { return }
        do {
            let v = try await RPC.shared.call("session/page", args: ["request": [
                "address": ["sessionId": sessionId, "kind": "session"], "maxMessages": 120,
            ]])
            items = Self.build((v["records"] as? [[String: Any]]) ?? [])
            errorText = nil
        } catch { errorText = error.localizedDescription }
    }

    static func build(_ records: [[String: Any]]) -> [ChatItem] {
        var out: [ChatItem] = []
        var results: [String: String] = [:]
        for rec in records {
            guard let e = rec["event"] as? [String: Any], let type = e["type"] as? String,
                  let d = e["data"] as? [String: Any] else { continue }
            if type == "tool/result" {
                let msg = d["message"] as? [String: Any] ?? [:]
                let callId = (msg["toolCallId"] as? String) ?? ((msg["source"] as? [String: Any])?["callId"] as? String) ?? ""
                let parts = (msg["content"] as? [[String: Any]]) ?? []
                let text = parts.compactMap { $0["text"] as? String }.joined()
                if !callId.isEmpty { results[callId] = text }
            }
        }
        for (i, rec) in records.enumerated() {
            guard let e = rec["event"] as? [String: Any], let type = e["type"] as? String,
                  let d = e["data"] as? [String: Any] else { continue }
            let id = "\(type)-\(i)"
            switch type {
            case "user/message":
                let parts = (d["content"] as? [[String: Any]]) ?? []
                let t = parts.compactMap { $0["text"] as? String }.joined()
                if !t.isEmpty { out.append(ChatItem(id: id, kind: .user, text: t)) }
            case "assistant/message":
                let msg = d["message"] as? [String: Any] ?? [:]
                let parts = (msg["content"] as? [[String: Any]]) ?? []
                let t = parts.compactMap { p in (p["type"] as? String) == "text" ? (p["text"] as? String) : nil }.joined()
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(ChatItem(id: id, kind: .assistant, text: t))
                }
            case "tool/call":
                let name = d["name"] as? String ?? "tool"
                let callId = d["callId"] as? String ?? ""
                out.append(ChatItem(id: id, kind: .tool, text: "", name: name,
                                    args: d["arguments"] as? String ?? "", result: results[callId]))
            case "turn/end":
                out.append(ChatItem(id: id, kind: .info, text: "— 本轮结束 —"))
            default: break
            }
        }
        return out
    }

    func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sessionId.isEmpty else { return }
        input = ""
        busy = true
        items.append(ChatItem(id: "local-\(UUID().uuidString)", kind: .user, text: text))
        do {
            _ = try await RPC.shared.call("session/prompt", args: ["request": [
                "requestId": UUID().uuidString, "sessionId": sessionId, "mode": "queue",
                "content": [["type": "text", "text": text]],
                "clientTimeZone": TimeZone.current.identifier,
            ]])
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

// MARK: - 组件

struct ToolCard: View {
    let item: ChatItem
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver.fill").font(.caption2)
                    Text(item.name ?? "tool").font(.system(.caption, design: .monospaced)).bold()
                    Text((item.args ?? "").replacingOccurrences(of: "\n", with: " ")).font(.caption2)
                        .foregroundColor(.secondary).lineLimit(1)
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2).foregroundColor(.secondary)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    Text("参数").font(.caption2).foregroundColor(.secondary)
                    Text(item.args ?? "").font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    if let r = item.result, !r.isEmpty {
                        Text("结果").font(.caption2).foregroundColor(.secondary).padding(.top, 2)
                        Text(String(r.prefix(2000))).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

struct Bubble: View {
    let item: ChatItem
    var body: some View {
        switch item.kind {
        case .user:
            HStack { Spacer(minLength: 50)
                Text(item.text).padding(11).foregroundColor(.white)
                    .background(kAccent).clipShape(RoundedRectangle(cornerRadius: 14))
            }
        case .assistant:
            HStack { Text(item.text).padding(11)
                .background(Color.secondary.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 14))
                Spacer(minLength: 50) }
        case .tool:
            ToolCard(item: item)
        case .info:
            Text(item.text).font(.caption2).foregroundColor(.secondary).frame(maxWidth: .infinity)
        }
    }
}

struct Composer: View {
    @ObservedObject var store: ChatStore
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
                    .lineLimit(1...5)
                    .padding(8)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Button {
                    Task { await store.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(store.input.trimmingCharacters(in: .whitespaces).isEmpty ? .secondary : kAccent)
                }
                .disabled(store.input.trimmingCharacters(in: .whitespaces).isEmpty || store.busy)
            }
            .padding(.horizontal, 12)
            HStack(spacing: 10) {
                Label("\(store.latency)ms", systemImage: "bolt.horizontal.fill")
                Text("·")
                Text(store.busy ? "生成中…" : "就绪")
                Spacer()
                Text("\(store.sessions.count) 个会话")
            }
            .font(.caption2).foregroundColor(.secondary)
            .padding(.horizontal, 14).padding(.bottom, 4)
        }
        .padding(.top, 6)
        .background(.bar)
    }
}

struct Drawer: View {
    @ObservedObject var store: ChatStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("会话").font(.headline)
                Spacer()
                Button { store.drawOpen = false } label: { Image(systemName: "xmark") }
            }.padding()
            List {
                Section("最近") {
                    ForEach(Array(store.sessions.prefix(15))) { s in row(s) }
                }
                if store.sessions.count > 15 {
                    Section("更早") {
                        ForEach(Array(store.sessions.dropFirst(15))) { s in row(s) }
                    }
                }
            }.listStyle(.insetGrouped)
        }
        .frame(maxWidth: 300)
        .background(.background)
    }
    func row(_ s: SessionRow) -> some View {
        Button {
            store.drawOpen = false
            Task { await store.open(s.id) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).lineLimit(1).font(.subheadline)
                    Text(String(s.id.prefix(8))).font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                if s.running { ProgressView().scaleEffect(0.6) }
                if s.id == store.sessionId { Image(systemName: "checkmark.circle.fill").foregroundColor(kAccent) }
            }
        }
    }
}

struct RootView: View {
    @StateObject private var store = ChatStore()
    @State private var showWeb = false

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                header
                content
                Composer(store: store)
            }
            if store.drawOpen {
                Color.black.opacity(0.25).ignoresSafeArea()
                    .onTapGesture { store.drawOpen = false }
                Drawer(store: store).transition(.move(edge: .leading))
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
        HStack(spacing: 14) {
            Button { store.drawOpen = true } label: { Image(systemName: "line.3.horizontal") }
            Spacer()
            Text(store.sessions.first(where: { $0.id == store.sessionId })?.title ?? "DSH")
                .font(.headline).lineLimit(1)
            Spacer()
            Button { Task { await store.refreshSessions(); await store.load() } } label: { Image(systemName: "arrow.clockwise") }
            Button { showWeb = true } label: { Image(systemName: "safari") }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.items.isEmpty { emptyState }
                    ForEach(store.items) { m in Bubble(item: m).id(m.id) }
                    if store.busy {
                        HStack(spacing: 6) { ProgressView().scaleEffect(0.7); Text("生成中…").font(.caption).foregroundColor(.secondary) }
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
            Spacer(minLength: 40)
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundColor(kAccent)
                Text("探索未至之境").font(.title3).bold()
            }
            Text("点下方建议开始，或直接输入").font(.caption).foregroundColor(.secondary)
            VStack(spacing: 10) {
                card("iPhone 现在什么状态", "三端口 + 最近报错", "查一下 iPhone 的引擎/代理/tweak 三端口状态和最近引擎日志")
                card("跑一遍操控回归", "20 项手机操控能力实测", "在 iPhone 上跑 phone-functest.mjs，给我通过率和失败项")
                card("重装后补丁有没有丢", "验 apply-patches 幂等", "跑 apply-patches.sh 看改动数，并解释每一处改动意味着什么")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private func card(_ title: String, _ sub: String, _ prompt: String) -> some View {
        Button { store.input = prompt } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline).bold()
                Text(sub).font(.caption2).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
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
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.rootViewController = UIHostingController(rootView: RootView())
        w.makeKeyAndVisible()
        window = w
        dshlog("native v2 up")
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool { true }
    func application(_ application: UIApplication, configurationForConnecting s: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: "Default Configuration", sessionRole: s.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
