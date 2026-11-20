import UIKit
import WebKit

// 极简原生壳：WKWebView 连本机 dsh 引擎（127.0.0.1:3080/?token=...）
// 越狱机上用 Theos 编译：make package THEOS_PACKAGE_SCHEME=rootless

final class ShellViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private var web: WKWebView!
    private let defaults = UserDefaults.standard
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
        loadEntry()
    }

    private func loadEntry() {
        // 1) 优先读引擎写下的带 token 地址
        if let s = try? String(contentsOfFile: "/var/mobile/Library/dsh/.web-url", encoding: .utf8),
           let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            defaults.set(u.absoluteString, forKey: urlKey)
            web.load(URLRequest(url: u)); return
        }
        // 2) 其次用已保存地址；3) 都没有就弹框让用户粘
        if let s = defaults.string(forKey: urlKey), let u = URL(string: s) {
            web.load(URLRequest(url: u)); return
        }
        askForURL()
    }

    private func askForURL() {
        let ac = UIAlertController(title: "dsh 引擎地址", message: "粘贴日志里的 http://127.0.0.1:3080/?token=...", preferredStyle: .alert)
        ac.addTextField { $0.placeholder = "http://127.0.0.1:3080/?token=…"; $0.text = "http://127.0.0.1:3080/" }
        ac.addAction(UIAlertAction(title: "连接", style: .default) { _ in
            guard let t = ac.textFields?.first?.text, let u = URL(string: t) else { return }
            self.defaults.set(t, forKey: self.urlKey)
            self.web.load(URLRequest(url: u))
        })
        present(ac, animated: true)
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
