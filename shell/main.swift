import UIKit
import SwiftUI
import SafariServices

// DSH Go 原生客户端（iPad/iPhone 原生 SwiftUI 界面，直接吃引擎的 typert RPC）
// 认证交给本地代理（127.0.0.1:3081，它自己跟引擎换 cookie），所以这里不需要处理 token。

let kBase = URL(string: "http://127.0.0.1:3081")!
let kWebFallback = URL(string: "http://127.0.0.1:3081/")!

// MARK: - 日志

func dshlog(_ msg: String) {
    let line = "[\(Int(Date().timeIntervalSince1970))] \(msg)\n"
    let data = line.data(using: .utf8)!
    if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
        let url = docs.appendingPathComponent("dsh-app.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }
}

// MARK: - RPC

struct RPCError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { "\(code): \(message)" }
}

actor RPC {
    static let shared = RPC()
    private var seq = 0

    func call(_ method: String, args: [String: Any]) async throws -> [String: Any] {
        seq += 1
        let body: [String: Any] = [
            "type": "client-request",
            "rpcId": "ios-\(seq)-\(Int(Date().timeIntervalSince1970))",
            "method": method,
            "payload": ["args": args],
        ]
        var req = URLRequest(url: kBase.appendingPathComponent("api/\(method)"))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw RPCError(code: "http", message: "状态码 \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            throw RPCError(code: "parse", message: String(data: data, encoding: .utf8)?.prefix(120).description ?? "")
        }
        if (result["ok"] as? Bool) == true {
            return (result["value"] as? [String: Any]) ?? [:]
        }
        let err = result["error"] as? [String: Any] ?? [:]
        throw RPCError(code: err["code"] as? String ?? "error", message: err["message"] as? String ?? "未知错误")
    }
}

// MARK: - 模型

struct ChatMessage: Identifiable, Equatable {
    enum Kind { case user, assistant, tool, info }
    let id: String
    var kind: Kind
    var text: String
    var toolName: String? = nil
}

struct SessionSummary: Identifiable, Equatable {
    let id: String
    var title: String
    var running: Bool
}

// MARK: - Store

@MainActor
final class ChatStore: ObservableObject {
    @Published var sessions: [SessionSummary] = []
    @Published var messages: [ChatMessage] = []
    @Published var sessionId: String = ""
    @Published var input: String = ""
    @Published var busy = false
    @Published var errorText: String?
    @Published var connected = false

    private var pollTask: Task<Void, Never>?

    func bootstrap() async {
        await refreshSessions()
        if sessionId.isEmpty, let first = sessions.first {
            await open(first.id)
        } else if sessionId.isEmpty {
            await newSession()
        }
        connected = true
    }

    func refreshSessions() async {
        do {
            let v = try await RPC.shared.call("session/list", args: ["_request": [:]])
            let items = (v["items"] as? [[String: Any]]) ?? []
            sessions = items.compactMap { item in
                guard let sid = item["sessionId"] as? String else { return nil }
                return SessionSummary(id: sid,
                                      title: (item["title"] as? String)?.isEmpty == false ? (item["title"] as! String) : String(sid.prefix(8)),
                                      running: (item["running"] as? Bool) ?? false)
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    func newSession() async {
        // 没有“新建会话”接口就复用最近一个；真正的新会话由第一条消息产生时引擎侧创建
        if let newest = sessions.first { await open(newest.id) }
    }

    func open(_ sid: String) async {
        sessionId = sid
        messages = []
        await loadPage()
        startPolling()
    }

    func loadPage() async {
        do {
            let v = try await RPC.shared.call("session/page", args: [
                "request": ["address": ["sessionId": sessionId, "kind": "session"], "maxMessages": 80],
            ])
            let records = (v["records"] as? [[String: Any]]) ?? []
            messages = Self.buildMessages(records)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    static func buildMessages(_ records: [[String: Any]]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for (i, rec) in records.enumerated() {
            guard let e = rec["event"] as? [String: Any],
                  let type = e["type"] as? String,
                  let data = e["data"] as? [String: Any] else { continue }
            let id = "\(type)-\(i)"
            switch type {
            case "user/message":
                let parts = (data["content"] as? [[String: Any]]) ?? []
                let text = parts.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty { out.append(ChatMessage(id: id, kind: .user, text: text)) }
            case "assistant/message":
                let msg = data["message"] as? [String: Any] ?? [:]
                let parts = (msg["content"] as? [[String: Any]]) ?? []
                var text = ""
                for p in parts {
                    if (p["type"] as? String) == "text", let t = p["text"] as? String { text += t }
                }
                if !text.isEmpty { out.append(ChatMessage(id: id, kind: .assistant, text: text)) }
            case "tool/call":
                let name = data["name"] as? String ?? "tool"
                let args = data["arguments"] as? String ?? ""
                out.append(ChatMessage(id: id, kind: .tool, text: String(args.prefix(120)), toolName: name))
            case "turn/end":
                let ok = ((data["status"] as? String) ?? "") != "error"
                out.append(ChatMessage(id: id, kind: .info, text: ok ? "— 本轮结束 —" : "— 本轮出错 —"))
            default:
                break
            }
        }
        return out
    }

    func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sessionId.isEmpty else { return }
        input = ""
        busy = true
        messages.append(ChatMessage(id: "local-\(UUID().uuidString)", kind: .user, text: text))
        do {
            _ = try await RPC.shared.call("session/prompt", args: [
                "request": [
                    "requestId": UUID().uuidString,
                    "sessionId": sessionId,
                    "mode": "standard",
                    "content": [["type": "text", "text": text]],
                    "clientTimeZone": TimeZone.current.identifier,
                ],
            ])
            startPolling()
        } catch {
            errorText = error.localizedDescription
            busy = false
        }
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            var quiet = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900_000_000)
                var running = false
                if let v = try? await RPC.shared.call("session/state", args: ["request": ["sessionId": self.sessionId]]) {
                    running = (v["running"] as? Bool) ?? false
                }
                await self.loadPage()
                await MainActor.run { self.busy = running }
                quiet = running ? 0 : quiet + 1
                if quiet >= 3 { break }
            }
        }
    }
}

// MARK: - 视图

struct MessageRow: View {
    let msg: ChatMessage
    var body: some View {
        switch msg.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(msg.text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        case .assistant:
            HStack {
                Text(msg.text)
                    .padding(10)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Spacer(minLength: 40)
            }
        case .tool:
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                Text(msg.toolName ?? "tool").bold()
                Text(msg.text).lineLimit(1).foregroundStyle(.secondary)
                Spacer()
            }
            .font(.caption)
            .padding(.vertical, 2)
        case .info:
            Text(msg.text).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }
}

struct ChatView: View {
    @StateObject private var store = ChatStore()
    @State private var showSessions = false
    @State private var showWeb = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.messages) { m in
                            MessageRow(msg: m).id(m.id)
                        }
                        if store.busy {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.7)
                                Text("生成中…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: store.messages.count) { _, _ in
                    if let last = store.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    TextField("发消息给 DSH…", text: $store.input, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Task { await store.send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                    }
                    .disabled(store.input.trimmingCharacters(in: .whitespaces).isEmpty || store.busy)
                }
                .padding(8)
                .background(.bar)
            }
            .navigationTitle("DSH")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSessions = true } label: { Image(systemName: "list.bullet") }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { Task { await store.refreshSessions(); await store.loadPage() } } label: { Image(systemName: "arrow.clockwise") }
                    Button { showWeb = true } label: { Image(systemName: "safari") }
                }
            }
            .sheet(isPresented: $showSessions) {
                SessionList(store: store) { showSessions = false }
            }
            .sheet(isPresented: $showWeb) { SafariView(url: kWebFallback) }
            .overlay(alignment: .top) {
                if let err = store.errorText {
                    Text(err).font(.caption2).foregroundStyle(.white)
                        .padding(6).background(.red.opacity(0.85))
                        .clipShape(Capsule()).padding(.top, 4)
                }
            }
            .task { await store.bootstrap() }
        }
    }
}

struct SessionList: View {
    @ObservedObject var store: ChatStore
    var close: () -> Void
    var body: some View {
        NavigationStack {
            List(store.sessions) { s in
                Button {
                    Task { await store.open(s.id) }
                    close()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.title).lineLimit(1)
                            Text(String(s.id.prefix(8))).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if s.running { ProgressView().scaleEffect(0.6) }
                        if s.id == store.sessionId { Image(systemName: "checkmark") }
                    }
                }
            }
            .navigationTitle("会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { close() } } }
        }
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
        w.rootViewController = UIHostingController(rootView: ChatView())
        w.makeKeyAndVisible()
        window = w
        dshlog("native UI up")
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool { true }
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let cfg = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        cfg.delegateClass = SceneDelegate.self
        return cfg
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
