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
        guard !opened else { return }
        opened = true
        if let u = resolveURL() { open(u) } else { showForm("没找到引擎地址。先在手机上跑：\nsh /var/mobile/Library/dsh/start-engine.sh\n然后把带 token 的地址粘进来：") }
    }

    private func resolveURL() -> URL? {
        for path in urlCandidates {
            guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { dshlog("read fail \(path)"); continue }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let u = URL(string: t), u.scheme != nil {
                dshlog("using \(u.absoluteString.prefix(40))")
                defaults.set(u.absoluteString, forKey: urlKey)
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
