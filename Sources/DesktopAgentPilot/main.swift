import AppKit

@main
@MainActor
final class DesktopAgentPilotApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let countLabel = NSTextField(labelWithString: "0")
    private let messageField = NSTextField(string: "欢迎使用 DesktopAgentPilot")
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private var clickCount = 0

    static func main() {
        let app = NSApplication.shared
        let delegate = DesktopAgentPilotApp()

        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        configureWindow()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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

        let mainMenu = NSMenu()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApplication.shared.mainMenu = mainMenu
    }

    private func configureWindow() {
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let titleLabel = NSTextField(labelWithString: "DesktopAgentPilot")
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.alignment = .center

        let subtitleLabel = NSTextField(labelWithString: "一个简单的原生 macOS 桌面端程序")
        subtitleLabel.font = .systemFont(ofSize: 15, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center

        messageField.placeholderString = "输入一段文字"
        messageField.font = .systemFont(ofSize: 15)
        messageField.bezelStyle = .roundedBezel
        messageField.controlSize = .large

        countLabel.font = .monospacedDigitSystemFont(ofSize: 54, weight: .semibold)
        countLabel.alignment = .center

        let incrementButton = NSButton(
            title: "点击计数",
            target: self,
            action: #selector(incrementCount)
        )
        incrementButton.bezelStyle = .rounded
        incrementButton.controlSize = .large

        let resetButton = NSButton(
            title: "重置",
            target: self,
            action: #selector(resetCount)
        )
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .large

        let buttonStack = NSStackView(views: [incrementButton, resetButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 12
        buttonStack.distribution = .fillEqually

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center

        let stack = NSStackView(views: [
            titleLabel,
            subtitleLabel,
            messageField,
            countLabel,
            buttonStack,
            statusLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -36),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            messageField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            incrementButton.heightAnchor.constraint(equalToConstant: 36),
            resetButton.heightAnchor.constraint(equalToConstant: 36)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DesktopAgentPilot"
        window.minSize = NSSize(width: 420, height: 320)
        window.contentView = contentView
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    @objc private func incrementCount() {
        clickCount += 1
        countLabel.stringValue = "\(clickCount)"
        statusLabel.stringValue = "已记录 \(clickCount) 次点击：\(messageField.stringValue)"
    }

    @objc private func resetCount() {
        clickCount = 0
        countLabel.stringValue = "0"
        statusLabel.stringValue = "Ready"
    }
}
