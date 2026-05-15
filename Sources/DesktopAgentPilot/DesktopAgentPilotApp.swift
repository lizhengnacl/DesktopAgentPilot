import AppKit
import CoreImage

final class RoundedGroupView: NSView {
    var fillColor: NSColor = .controlBackgroundColor {
        didSet { needsDisplay = true }
    }
    var strokeColor: NSColor = .separatorColor {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        fillColor.setFill()
        path.fill()
        strokeColor.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

@main
@MainActor
final class DesktopAgentPilotApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let server = AgentPilotServer()
    private let powerManager = PowerAssertionManager()
    private let statusDot = NSView()
    private let stateSymbolView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "未启动")
    private let statusDetailLabel = NSTextField(labelWithString: "服务尚未启动")
    private let httpValueLabel = NSTextField(labelWithString: "")
    private let websocketValueLabel = NSTextField(labelWithString: "")
    private let healthValueLabel = NSTextField(labelWithString: "")
    private let awakeValueLabel = NSTextField(labelWithString: "")
    private let qrCodeImageView = NSImageView()
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
        configurePowerAssertionHandling()
        updateServiceStatus(AgentPilotServiceUpdate(state: .stopped, message: "服务尚未启动"))
        startServer()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        powerManager.stop()
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
        let contentView = NSVisualEffectView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.material = .underWindowBackground
        contentView.blendingMode = .behindWindow
        contentView.state = .active

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = NSApplication.shared.applicationIconImage

        let titleLabel = NSTextField(labelWithString: "DesktopAgentPilot")
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.alignment = .left

        let subtitleLabel = NSTextField(labelWithString: "管理本机 AgentPilot API 与 WebSocket 服务")
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .left

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 4

        let headerStack = NSStackView(views: [iconView, titleStack])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 12
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 42),
            iconView.heightAnchor.constraint(equalToConstant: 42),
        ])

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

        stateSymbolView.translatesAutoresizingMaskIntoConstraints = false
        stateSymbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        stateSymbolView.contentTintColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            stateSymbolView.widthAnchor.constraint(equalToConstant: 24),
            stateSymbolView.heightAnchor.constraint(equalToConstant: 24),
        ])

        let statusTextStack = NSStackView(views: [statusLabel, statusDetailLabel])
        statusTextStack.orientation = .vertical
        statusTextStack.alignment = .leading
        statusTextStack.spacing = 4

        let statusTitleStack = NSStackView(views: [statusDot, statusTextStack])
        statusTitleStack.orientation = .horizontal
        statusTitleStack.alignment = .centerY
        statusTitleStack.spacing = 10

        let statusStack = NSStackView(views: [stateSymbolView, statusTitleStack])
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 12
        statusStack.translatesAutoresizingMaskIntoConstraints = false

        let statusPanel = makeGroupView(content: statusStack, edgeInsets: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))

        httpValueLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        websocketValueLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        healthValueLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        awakeValueLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        qrCodeImageView.translatesAutoresizingMaskIntoConstraints = false
        qrCodeImageView.imageAlignment = .alignCenter
        qrCodeImageView.imageScaling = .scaleProportionallyUpOrDown
        qrCodeImageView.wantsLayer = true
        qrCodeImageView.layer?.backgroundColor = NSColor.white.cgColor
        qrCodeImageView.layer?.cornerRadius = 6

        let detailStack = NSStackView(views: [
            makeInfoRow(title: "HTTP", valueLabel: httpValueLabel),
            makeInfoRow(title: "WebSocket", valueLabel: websocketValueLabel),
            makeInfoRow(title: "健康检查", valueLabel: healthValueLabel),
            makeInfoRow(title: "保持唤醒", valueLabel: awakeValueLabel),
        ])
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 8
        let qrTitleLabel = NSTextField(labelWithString: "服务器二维码")
        qrTitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        qrTitleLabel.textColor = .secondaryLabelColor
        qrTitleLabel.alignment = .center

        let qrStack = NSStackView(views: [qrTitleLabel, qrCodeImageView])
        qrStack.orientation = .vertical
        qrStack.alignment = .centerX
        qrStack.spacing = 8
        NSLayoutConstraint.activate([
            qrCodeImageView.widthAnchor.constraint(equalToConstant: 124),
            qrCodeImageView.heightAnchor.constraint(equalToConstant: 124),
        ])

        let serviceInfoStack = NSStackView(views: [detailStack, qrStack])
        serviceInfoStack.orientation = .horizontal
        serviceInfoStack.alignment = .top
        serviceInfoStack.spacing = 18
        serviceInfoStack.distribution = .fill
        let detailPanel = makeGroupView(content: serviceInfoStack, edgeInsets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))

        startButton.target = self
        startButton.action = #selector(startServerFromControl(_:))
        startButton.bezelStyle = .rounded
        startButton.controlSize = .large
        startButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "启动")
        startButton.imagePosition = .imageLeading
        startButton.toolTip = "启动本机服务"
        startButton.keyEquivalent = "\r"

        stopButton.target = self
        stopButton.action = #selector(stopServerFromControl(_:))
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .large
        stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "关闭")
        stopButton.imagePosition = .imageLeading
        stopButton.toolTip = "关闭本机服务"

        let buttonStack = NSStackView(views: [startButton, stopButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 12

        let footerLabel = NSTextField(labelWithString: "关闭服务会断开当前 HTTP 与 WebSocket 连接；再次启动后客户端可重新连接。")
        footerLabel.font = .systemFont(ofSize: 12)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.alignment = .left
        footerLabel.lineBreakMode = .byWordWrapping
        footerLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [
            headerStack,
            statusPanel,
            detailPanel,
            buttonStack,
            footerLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -36),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 42),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -28),
            statusPanel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailPanel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DesktopAgentPilot"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.minSize = NSSize(width: 620, height: 430)
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

    private func configurePowerAssertionHandling() {
        powerManager.stateChanged = { [weak self] state in
            self?.updatePowerAssertionStatus(state)
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

    private func updatePowerAssertionStatus(_ state: PowerAssertionState) {
        awakeValueLabel.stringValue = powerAssertionText(for: state)
    }

    private func updateServiceStatus(_ update: AgentPilotServiceUpdate) {
        statusLabel.stringValue = title(for: update.state)
        statusDetailLabel.stringValue = update.message
        statusDot.layer?.backgroundColor = color(for: update.state).cgColor
        stateSymbolView.image = symbol(for: update.state)
        stateSymbolView.contentTintColor = color(for: update.state)

        let port = server.listenPort
        let host = LocalNetworkAddress.currentIPv4()
        let serverAddress = "http://\(host):\(port)"
        httpValueLabel.stringValue = serverAddress
        websocketValueLabel.stringValue = "ws://\(host):\(port)"
        healthValueLabel.stringValue = "http://\(host):\(port)/health  ->  AgentPilot Server"
        qrCodeImageView.image = makeQRCodeImage(text: serverAddress, size: 124)

        let canStart = update.state == .stopped || update.state == .failed
        let canStop = update.state == .starting || update.state == .running
        startButton.isEnabled = canStart
        stopButton.isEnabled = canStop
        startMenuItem?.isEnabled = canStart
        stopMenuItem?.isEnabled = canStop
        updatePowerAssertion(for: update.state)
    }

    private func updatePowerAssertion(for serviceState: AgentPilotServiceState) {
        switch serviceState {
        case .starting, .running:
            if !powerManager.isPreventingSleep {
                powerManager.start()
            }
        case .stopped, .failed:
            if powerManager.isPreventingSleep {
                powerManager.stop()
            } else {
                updatePowerAssertionStatus(powerManager.state)
            }
        }
    }

    private func powerAssertionText(for state: PowerAssertionState) -> String {
        switch state {
        case .inactive:
            return "未启用"
        case .active:
            return "服务运行期间一直启用"
        case .partial(let detail):
            return detail
        case .unavailable(let detail):
            return detail
        }
    }

    private func makeGroupView(content: NSView, edgeInsets: NSEdgeInsets) -> NSView {
        let groupView = RoundedGroupView()
        groupView.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        groupView.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: groupView.leadingAnchor, constant: edgeInsets.left),
            content.trailingAnchor.constraint(equalTo: groupView.trailingAnchor, constant: -edgeInsets.right),
            content.topAnchor.constraint(equalTo: groupView.topAnchor, constant: edgeInsets.top),
            content.bottomAnchor.constraint(equalTo: groupView.bottomAnchor, constant: -edgeInsets.bottom),
        ])
        return groupView
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

    private func makeQRCodeImage(text: String, size: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator"),
              let data = text.data(using: .utf8) else {
            return nil
        }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }

        let inset: CGFloat = 8
        let targetSize = size - inset * 2
        let scale = max(1, floor(targetSize / outputImage.extent.width))
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        let qrSize = scaledImage.extent.width
        NSImage(cgImage: cgImage, size: NSSize(width: qrSize, height: qrSize)).draw(
            in: NSRect(x: (size - qrSize) / 2, y: (size - qrSize) / 2, width: qrSize, height: qrSize),
            from: NSRect(x: 0, y: 0, width: qrSize, height: qrSize),
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        return image
    }

    private func title(for state: AgentPilotServiceState) -> String {
        switch state {
        case .stopped: return "服务未启动"
        case .starting: return "服务启动中"
        case .running: return "服务运行中"
        case .failed: return "服务启动失败"
        }
    }

    private func symbol(for state: AgentPilotServiceState) -> NSImage? {
        switch state {
        case .stopped:
            return NSImage(systemSymbolName: "power.circle", accessibilityDescription: "服务未启动")
        case .starting:
            return NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "服务启动中")
        case .running:
            return NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "服务运行中")
        case .failed:
            return NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "服务启动失败")
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
