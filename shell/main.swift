import UIKit
import WebKit

// 全局日志：写到 Documents/dsh-app.log（还兜底写 /tmp，沙盒外也能看）
func dshlog(_ msg: String) {
    let line = "[\(Int(Date().timeIntervalSince1970))] \(msg)\n"
    let data = line.data(using: .utf8)!
    if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
        let url = docs.appendingPathComponent("dsh-app.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
    if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/dsh-go-shell.log")) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: "/tmp/dsh-go-shell.log"))
    }
}

// 极简原生壳：WKWebView 连本机 dsh 引擎（127.0.0.1:3080/?token=...）
// 越狱机上用 Theos 编译：make package THEOS_PACKAGE_SCHEME=rootless

final class ShellViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var web: WKWebView!
    private let defaults = UserDefaults.standard


    private let urlKey = "dsh.web.url"

    override func viewDidLoad() {
        super.viewDidLoad()
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // 把页面里的 console / 未捕获错误回传出来，WKWebView 里没有 Safari 的 Web Inspector
        cfg.userContentController.add(self, name: "dshlog")
        let hook = """
        (function(){
          function send(kind, args){
            try { window.webkit.messageHandlers.dshlog.postMessage(kind + ': ' + Array.prototype.map.call(args, function(a){
              try { return (typeof a === 'object') ? JSON.stringify(a).slice(0,300) : String(a); } catch(e){ return String(a); }
            }).join(' ')); } catch(e){}
          }
          ['error','warn'].forEach(function(k){ var o=console[k]; console[k]=function(){ send(k, arguments); return o.apply(console, arguments); }; });
          window.addEventListener('error', function(e){ send('onerror', [e.message + ' @' + (e.filename||'') + ':' + (e.lineno||0)]); });
          window.addEventListener('unhandledrejection', function(e){ send('rejection', [String(e.reason && (e.reason.stack||e.reason.message||e.reason) || 'unknown')]); });
        })();
        """
        cfg.userContentController.addUserScript(WKUserScript(source: hook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        // 用 Auto Layout 铺满：viewDidLoad 阶段 view.bounds 可能是 0，
        // 用 frame 会导致 webview 尺寸为 0 —— 进程都在、界面全灰、也不报错。
        web = WKWebView(frame: .zero, configuration: cfg)
        web.translatesAutoresizingMaskIntoConstraints = false
        web.navigationDelegate = self
        web.uiDelegate = self
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.topAnchor.constraint(equalTo: view.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        UIApplication.shared.isIdleTimerDisabled = true
        dshlog("viewDidLoad start")
        loadEntry()
    }

    // 地址来源，按优先级：
    //   1) 自己沙盒里的 Documents/dsh-url.txt（引擎/脚本会写，最可靠）
    //   2) 系统中转文件（万一 App 拿到 no-sandbox 权限）
    //   3) UserDefaults 里上次用的
    //   4) 都没有 → 就地显示输入框（不再用 alert，viewDidLoad 里弹框会静默失败）
    private var urlCandidates: [String] {
        var list: [String] = []
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            list.append(docs.appendingPathComponent("dsh-url.txt").path)
        }
        list.append("/var/mobile/Library/dsh/.web-url")
        list.append("/var/mobile/Documents/dsh-url.txt")
        return list
    }

    private func loadEntry() {
        dshlog("docs=" + (( FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path) ?? "nil"))
        for path in urlCandidates {
            guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { dshlog("read fail: \(path)"); continue }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let u = URL(string: trimmed), u.scheme != nil else { dshlog("bad url in \(path)"); continue }
            dshlog("using \(u.absoluteString.prefix(40))")
            defaults.set(u.absoluteString, forKey: urlKey)
            hideEntryForm()
            bootstrap(tokenURL: u)
            return
        }
        if let s = defaults.string(forKey: urlKey), let u = URL(string: s), u.scheme != nil {
            hideEntryForm()
            bootstrap(tokenURL: u)
            return
        }
        dshlog("no url found, showing form")
        showEntryForm("没有找到引擎地址。先在手机上跑：\nsh /var/mobile/Library/dsh/start-engine.sh\n然后把带 token 的地址粘进来：")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "dshlog" { dshlog("js " + String(describing: message.body)) }
    }

    /// 先用 URLSession 请求带 token 的地址，**拦下 303 不跟随**，只取 Set-Cookie，
    /// 写进 WKWebView 的 cookie store，再打开首页。
    /// （不拦的话 URLSession 会跟着跳到 /，而那一跳没带 cookie → 401，
    ///    SPA 的插件包也就拿不到会话，界面会一直停在 "Loading plugins…"）
    private func bootstrap(tokenURL: URL) {
        dshlog("bootstrap \(tokenURL.absoluteString.prefix(40))")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg, delegate: RedirectCatcher.shared, delegateQueue: nil)
        var req = URLRequest(url: tokenURL)
        req.httpShouldHandleCookies = false
        RedirectCatcher.shared.onRedirect = { [weak self] response in
            guard let self else { return }
            var cookies: [HTTPCookie] = []
            if let fields = response.allHeaderFields as? [String: String] {
                cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: tokenURL)
            }
            dshlog("bootstrap status \(response.statusCode) cookies=\(cookies.count)")
            let store = WKWebsiteDataStore.default().httpCookieStore
            let group = DispatchGroup()
            for c in cookies { group.enter(); store.setCookie(c) { group.leave() } }
            group.notify(queue: .main) {
                self.web.load(URLRequest(url: URL(string: "http://127.0.0.1:3080/")!))
            }
        }
        session.dataTask(with: req) { [weak self] _, resp, err in
            guard let self else { return }
            if let e = err { dshlog("bootstrap err \(e.localizedDescription)") }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                dshlog("bootstrap final \(http.statusCode)")
            }
            DispatchQueue.main.async {
                if self.web.url == nil {
                    self.web.load(URLRequest(url: URL(string: "http://127.0.0.1:3080/")!))
                }
            }
        }.resume()
    }

    // —— 内联输入框（替代 alert）——
    private var form: UIView?
    private var field: UITextField?

    private func showEntryForm(_ hint: String) {
        hideEntryForm()
        let box = UIView(frame: view.bounds)
        box.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        box.backgroundColor = .systemBackground

        let label = UILabel()
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 15)
        label.text = hint
        label.translatesAutoresizingMaskIntoConstraints = false

        let tf = UITextField()
        tf.borderStyle = .roundedRect
        tf.placeholder = "http://127.0.0.1:3080/?token=…"
        tf.autocapitalizationType = .none
        tf.autocorrectionType = .no
        tf.translatesAutoresizingMaskIntoConstraints = false
        field = tf

        let btn = UIButton(type: .system)
        btn.setTitle("打开", for: .normal)
        btn.titleLabel?.font = .boldSystemFont(ofSize: 17)
        btn.addTarget(self, action: #selector(submitForm), for: .touchUpInside)
        btn.translatesAutoresizingMaskIntoConstraints = false

        box.addSubview(label); box.addSubview(tf); box.addSubview(btn)
        view.addSubview(box)
        form = box

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -24),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 120),
            tf.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            tf.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            tf.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            btn.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            btn.topAnchor.constraint(equalTo: tf.bottomAnchor, constant: 20),
        ])
    }

    private func hideEntryForm() {
        form?.removeFromSuperview()
        form = nil
        field = nil
    }

    @objc private func submitForm() {
        guard let text = field?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              let u = URL(string: text), u.scheme != nil else { return }
        defaults.set(u.absoluteString, forKey: urlKey)
        hideEntryForm()
        web.load(URLRequest(url: u))
    }

    private func askForURL() {
        showEntryForm("把带 token 的地址粘进来：")
    }

    // 加载失败要说清楚原因，别只留一片灰
    func webView(_ w: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        dshlog("didFailProvisional: \(error.localizedDescription)")
        showEntryForm("打不开引擎界面：\(error.localizedDescription)\n先确认引擎在跑，再粘地址：")
    }

    func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        dshlog("didFail: \(error.localizedDescription)")
        showEntryForm("加载失败：\(error.localizedDescription)")
    }

    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
        dshlog("didFinish url=\(w.url?.absoluteString.prefix(50) ?? "?") title=\(w.title ?? "nil")")
        w.evaluateJavaScript("(document.body ? document.body.innerText.slice(0,120) : 'nobody') + ' || html=' + (document.documentElement ? document.documentElement.outerHTML.length : 0)") { v, e in
            dshlog("probe: \(e.map { "err \($0.localizedDescription)" } ?? String(describing: v))")
            w.evaluateJavaScript("window.innerWidth + 'x' + window.innerHeight") { s, _ in
                dshlog("viewport: \(s.map { String(describing: $0) } ?? "?")")
            }
        }
    }

    // 外部 http 链接交给系统
    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = action.request.url, let h = u.host else { return decisionHandler(.allow) }
        if h == "127.0.0.1" || h == "localhost" { return decisionHandler(.allow) }
        UIApplication.shared.open(u); decisionHandler(.cancel)
    }
}

// 拦下 303：只取 Set-Cookie，不让 URLSession 自己跳
final class RedirectCatcher: NSObject, URLSessionTaskDelegate {
    static let shared = RedirectCatcher()
    var onRedirect: ((HTTPURLResponse) -> Void)?
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        onRedirect?(response)
        completionHandler(nil)   // 不跟随
    }
}

// iOS 26 起强制 Scene 生命周期：只有 AppDelegate + window 的壳拿不到窗口，
// 表现为「进程在跑、界面全灰、连 viewDidLoad 都不进」。
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        dshlog("scene willConnect")
        guard let ws = scene as? UIWindowScene else { dshlog("scene cast failed"); return }
        let w = UIWindow(windowScene: ws)
        w.rootViewController = ShellViewController()
        w.makeKeyAndVisible()
        window = w
        dshlog("window visible")
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ app: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        dshlog("didFinishLaunching")
        return true
    }

    // 用代码指定 scene 配置，避免 Info.plist 里写 $(PRODUCT_MODULE_NAME)（swiftc 不替换）
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let cfg = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        cfg.delegateClass = SceneDelegate.self
        return cfg
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
