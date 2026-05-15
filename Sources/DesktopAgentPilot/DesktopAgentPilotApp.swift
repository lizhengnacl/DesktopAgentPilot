import AppKit

@main
@MainActor
final class DesktopAgentPilotApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let server = AgentPilotServer()
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "未启动")
    private let statusDetailLabel = NSTextField(labelWithString: "服务尚未启动")
    private let httpValueLabel = NSTextField(labelWithString: "")
    private let websocketValueLabel = NSTextField(labelWithString: "")
    private let healthValueLabel = NSTextField(labelWithString: "")
    private let startButton = NSButton(title: "启动服务", target: nil, action: nil)
    private let stopButton = NSButton(title: "关闭服务", target: nil, action: nil)
    private var startMenuItem: NSMenuItem?
    private var stopMenuItem: NSMenuItem?

    static func main() {
        let app = NSApplication.shared
        let delegate = DesktopAgentPilotApp()

        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureAppIcon()
        configureMenu()
        configureWindow()
        configureServerStatusHandling()
        updateServiceStatus(AgentPilotServiceUpdate(state: .stopped, message: "服务尚未启动"))
        startServer()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    private func configureAppIcon() {
        let iconURLs = [
            Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
            Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
        ]

        if let iconURL = iconURLs.compactMap({ $0 }).first,
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    private func configureMenu() {
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let quitItem = NSMenuItem(
            title: "Quit DesktopAgentPilot",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        appMenu.addItem(quitItem)

        let serviceMenu = NSMenu(title: "服务")
        let serviceMenuItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let startMenuItem = NSMenuItem(title: "启动服务", action: #selector(startServerFromControl(_:)), keyEquivalent: "r")
        let stopMenuItem = NSMenuItem(title: "关闭服务", action: #selector(stopServerFromControl(_:)), keyEquivalent: ".")
        startMenuItem.target = self
        stopMenuItem.target = self
        serviceMenu.addItem(startMenuItem)
        serviceMenu.addItem(stopMenuItem)
        serviceMenuItem.submenu = serviceMenu
        self.startMenuItem = startMenuItem
        self.stopMenuItem = stopMenuItem

        let mainMenu = NSMenu()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        mainMenu.addItem(serviceMenuItem)
        NSApplication.shared.mainMenu = mainMenu
    }

    private func configureWindow() {
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let titleLabel = NSTextField(labelWithString: "DesktopAgentPilot")
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.alignment = .left

        let subtitleLabel = NSTextField(labelWithString: "本机 AgentPilot 桥接服务")
        subtitleLabel.font = .systemFont(ofSize: 15, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .left

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 6

        statusLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        statusLabel.alignment = .left

        statusDetailLabel.font = .systemFont(ofSize: 13)
        statusDetailLabel.textColor = .secondaryLabelColor
        statusDetailLabel.alignment = .left
        statusDetailLabel.lineBreakMode = .byWordWrapping
        statusDetailLabel.maximumNumberOfLines = 2

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),
        ])

        let statusTextStack = NSStackView(views: [statusLabel, statusDetailLabel])
        statusTextStack.orientation = .vertical
        statusTextStack.alignment = .leading
        statusTextStack.spacing = 4

        let statusStack = NSStackView(views: [statusDot, statusTextStack])
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 10
        statusStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        statusStack.wantsLayer = true
        statusStack.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        statusStack.layer?.cornerRadius = 8

        httpValueLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        websocketValueLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        healthValueLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)

        let detailStack = NSStackView(views: [
            makeInfoRow(title: "HTTP", valueLabel: httpValueLabel),
            makeInfoRow(title: "WebSocket", valueLabel: websocketValueLabel),
            makeInfoRow(title: "健康检查", valueLabel: healthValueLabel),
        ])
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 8

        startButton.target = self
        startButton.action = #selector(startServerFromControl(_:))
        startButton.bezelStyle = .rounded
        startButton.controlSize = .large

        stopButton.target = self
        stopButton.action = #selector(stopServerFromControl(_:))
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .large

        let buttonStack = NSStackView(views: [startButton, stopButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 12

        let footerLabel = NSTextField(labelWithString: "关闭服务后，本机 API 与 WebSocket 连接会立即断开。")
        footerLabel.font = .systemFont(ofSize: 12)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.alignment = .left

        let stack = NSStackView(views: [
            titleStack,
            statusStack,
            detailStack,
            buttonStack,
            footerLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -36),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 34),
            statusStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DesktopAgentPilot"
        window.minSize = NSSize(width: 520, height: 340)
        window.contentView = contentView
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    private func configureServerStatusHandling() {
        server.statusChanged = { [weak self] status in
            self?.updateServiceStatus(status)
        }
    }

    private func startServer() {
        updateServiceStatus(AgentPilotServiceUpdate(state: .starting, message: "正在绑定本机端口 \(server.listenPort)..."))
        do {
            try server.start()
        } catch {
            updateServiceStatus(AgentPilotServiceUpdate(state: .failed, message: "请确认 \(server.listenPort) 端口未被占用: \(error.localizedDescription)"))
        }
    }

    private func stopServer() {
        server.stop()
    }

    private func updateServiceStatus(_ update: AgentPilotServiceUpdate) {
        statusLabel.stringValue = title(for: update.state)
        statusDetailLabel.stringValue = update.message
        statusDot.layer?.backgroundColor = color(for: update.state).cgColor

        let port = server.listenPort
        httpValueLabel.stringValue = "http://localhost:\(port)"
        websocketValueLabel.stringValue = "ws://localhost:\(port)"
        healthValueLabel.stringValue = "GET /health -> AgentPilot Server"

        let canStart = update.state == .stopped || update.state == .failed
        let canStop = update.state == .starting || update.state == .running
        startButton.isEnabled = canStart
        stopButton.isEnabled = canStop
        startMenuItem?.isEnabled = canStart
        stopMenuItem?.isEnabled = canStop
    }

    private func makeInfoRow(title: String, valueLabel: NSTextField) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .left
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .left
        valueLabel.lineBreakMode = .byTruncatingMiddle

        let row = NSStackView(views: [titleLabel, valueLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 14
        NSLayoutConstraint.activate([
            titleLabel.widthAnchor.constraint(equalToConstant: 86),
        ])
        return row
    }

    private func title(for state: AgentPilotServiceState) -> String {
        switch state {
        case .stopped: return "服务未启动"
        case .starting: return "服务启动中"
        case .running: return "服务运行中"
        case .failed: return "服务启动失败"
        }
    }

    private func color(for state: AgentPilotServiceState) -> NSColor {
        switch state {
        case .stopped: return .tertiaryLabelColor
        case .starting: return .systemOrange
        case .running: return .systemGreen
        case .failed: return .systemRed
        }
    }

    @objc private func startServerFromControl(_ sender: Any?) {
        startServer()
    }

    @objc private func stopServerFromControl(_ sender: Any?) {
        stopServer()
    }
}
