import UIKit
import SafariServices

// DSH Go 壳：不再自建 WKWebView（在这台越狱机上内容层不出画），
// 改用 SFSafariViewController —— 页面跑在系统的 SafariViewService 里，
// 渲染通道和 Safari 一致，界面仍然嵌在本 App 内。

// 全局日志：Documents/dsh-app.log + /tmp（沙盒外也能看）
func dshlog(_ msg: String) {
    let line = "[\(Int(Date().timeIntervalSince1970))] \(msg)\n"
    let data = line.data(using: .utf8)!
    if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
        let url = docs.appendingPathComponent("dsh-app.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }
    if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/dsh-go-shell.log")) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else { try? data.write(to: URL(fileURLWithPath: "/tmp/dsh-go-shell.log")) }
}

final class ShellViewController: UIViewController, UITextFieldDelegate {
    private let defaults = UserDefaults.standard
    private let urlKey = "dsh.web.url"
    /// 本地反向代理（auth-proxy.mjs）的固定地址：它自己去引擎换 cookie，
    /// 所以这个地址永远有效 —— 引擎重启、token 变化都不用重新配对。
    private let proxyURL = "http://127.0.0.1:3081/"
    private var currentToken = ""
    private var safariVC: SFSafariViewController?
    private var field: UITextField?
    private var opened = false

    private var urlCandidates: [String] {
        var list: [String] = []
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            list.append(docs.appendingPathComponent("dsh-url.txt").path)
        }
        list.append("/var/mobile/Library/dsh/.web-url")
        list.append("/var/mobile/Documents/dsh-url.txt")
        return list
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        dshlog("viewDidLoad")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !opened {
            opened = true
            // 优先用容器里的 token（boot-start 会持续刷新它）——直连引擎最稳；
            // 代理作为兜底（token 文件缺失/引擎未起时仍能让界面起来）。
            if let u = resolveURL() { open(u); return }
            if probeProxy() { open(URL(string: proxyURL)!); return } else {
                showForm("没找到引擎地址。先在手机上跑：\nsh /var/mobile/Library/dsh/start-engine.sh\n然后把带 token 的地址粘进来：")
                return
            }
        }
        maybeReloadForNewToken()
    }

    /// 引擎重启后 token 会变（dsh 每次启动随机生成）。回到前台时比对 .web-url，
    /// 变了就静默重开，省掉“手动重新配对”这一步。
    private func maybeReloadForNewToken() {
        guard let fresh = tokenURL(), fresh != currentToken else { return }
        dshlog("token changed -> reload")
        currentToken = fresh
        defaults.set(fresh, forKey: urlKey)
        safariVC?.dismiss(animated: false) { [weak self] in
            guard let self, let u = URL(string: fresh) else { return }
            self.open(u)
        }
    }

    /// 探一下本地代理是否在跑（2 秒超时）。在跑就用固定地址。
    private func probeProxy() -> Bool {
        guard let u = URL(string: proxyURL) else { return false }
        var req = URLRequest(url: u)
        req.timeoutInterval = 2
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode < 500 { ok = true }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2.5)
        dshlog("probeProxy ok=\(ok)")
        return ok
    }

    private func tokenURL() -> String? {
        for path in urlCandidates {
            if let s = try? String(contentsOfFile: path, encoding: .utf8) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.hasPrefix("http"), let u = URL(string: t), u.scheme != nil { return u.absoluteString }
            }
        }
        return defaults.string(forKey: urlKey)
    }

    private func resolveURL() -> URL? {
        for path in urlCandidates {
            guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { dshlog("read fail \(path)"); continue }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let u = URL(string: t), u.scheme != nil {
                dshlog("using \(u.absoluteString.prefix(40))")
                defaults.set(u.absoluteString, forKey: urlKey)
                currentToken = u.absoluteString
                return u
            }
            dshlog("bad url in \(path)")
        }
        if let s = defaults.string(forKey: urlKey), let u = URL(string: s), u.scheme != nil {
            dshlog("using saved \(u.absoluteString.prefix(40))")
            return u
        }
        dshlog("no url")
        return nil
    }

    private func open(_ url: URL) {
        dshlog("SFSafariViewController \(url.absoluteString.prefix(40))")
        let cfg = SFSafariViewController.Configuration()
        cfg.entersReaderIfAvailable = false
        let vc = SFSafariViewController(url: url, configuration: cfg)
        vc.preferredControlTintColor = .systemBlue
        vc.dismissButtonStyle = .close
        vc.delegate = self
        vc.modalPresentationStyle = .fullScreen
        safariVC = vc
        present(vc, animated: false) {
            dshlog("safari vc presented")
        }
    }

    // —— 兜底输入框 ——
    private func showForm(_ hint: String) {
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
        tf.delegate = self
        tf.translatesAutoresizingMaskIntoConstraints = false
        field = tf

        let btn = UIButton(type: .system)
        btn.setTitle("打开", for: .normal)
        btn.titleLabel?.font = .boldSystemFont(ofSize: 17)
        btn.addTarget(self, action: #selector(submit), for: .touchUpInside)
        btn.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(label); view.addSubview(tf); view.addSubview(btn)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 120),
            tf.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            tf.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            tf.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            btn.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            btn.topAnchor.constraint(equalTo: tf.bottomAnchor, constant: 20),
        ])
    }

    @objc private func submit() {
        guard let t = field?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              let u = URL(string: t), u.scheme != nil else { return }
        defaults.set(u.absoluteString, forKey: urlKey)
        field?.resignFirstResponder()
        open(u)
    }
}

extension ShellViewController: SFSafariViewControllerDelegate {
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        dshlog("safari closed")
    }
}

// iOS 26 强制 Scene 生命周期
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        dshlog("scene willConnect")
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.rootViewController = ShellViewController()
        w.makeKeyAndVisible()
        window = w
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        dshlog("didFinishLaunching")
        return true
    }
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let cfg = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        cfg.delegateClass = SceneDelegate.self
        return cfg
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
