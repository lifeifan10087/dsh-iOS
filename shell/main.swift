import UIKit
import WebKit

// 极简原生壳：WKWebView 连本机 dsh 引擎（127.0.0.1:3080/?token=...）
// 越狱机上用 Theos 编译：make package THEOS_PACKAGE_SCHEME=rootless

final class ShellViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private var web: WKWebView!
    private let defaults = UserDefaults.standard

    // 极简文件日志：写到自己的 Documents/dsh-app.log，方便从 SSH 侧看它卡在哪
    private func log(_ msg: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent("dsh-app.log")
        let line = "[~(Int(Date().timeIntervalSince1970))] \(msg)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }
    private let urlKey = "dsh.web.url"

    override func viewDidLoad() {
        super.viewDidLoad()
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        web = WKWebView(frame: view.bounds, configuration: cfg)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.navigationDelegate = self
        web.uiDelegate = self
        view.addSubview(web)
        UIApplication.shared.isIdleTimerDisabled = true
        log("viewDidLoad start")
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
        log("docs=" + (( FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path) ?? "nil"))
        for path in urlCandidates {
            guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { log("read fail: \(path)"); continue }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let u = URL(string: trimmed), u.scheme != nil else { log("bad url in \(path)"); continue }
            log("using \(u.absoluteString.prefix(40))")
            defaults.set(u.absoluteString, forKey: urlKey)
            hideEntryForm()
            web.load(URLRequest(url: u))
            return
        }
        if let s = defaults.string(forKey: urlKey), let u = URL(string: s), u.scheme != nil {
            hideEntryForm()
            web.load(URLRequest(url: u))
            return
        }
        log("no url found, showing form")
        showEntryForm("没有找到引擎地址。先在手机上跑：\nsh /var/mobile/Library/dsh/start-engine.sh\n然后把带 token 的地址粘进来：")
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
        log("didFailProvisional: \(error.localizedDescription)")
        showEntryForm("打不开引擎界面：\(error.localizedDescription)\n先确认引擎在跑，再粘地址：")
    }

    func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("didFail: \(error.localizedDescription)")
        showEntryForm("加载失败：\(error.localizedDescription)")
    }

    // 外部 http 链接交给系统
    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = action.request.url, let h = u.host else { return decisionHandler(.allow) }
        if h == "127.0.0.1" || h == "localhost" { return decisionHandler(.allow) }
        UIApplication.shared.open(u); decisionHandler(.cancel)
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ app: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = ShellViewController()
        window?.makeKeyAndVisible()
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
