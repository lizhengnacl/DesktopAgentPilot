# DesktopAgentPilot

一个最小可运行的原生 macOS 桌面端程序，使用 Swift Package Manager 和 AppKit 构建，无第三方依赖。

## 运行

```bash
swift run DesktopAgentPilot
```

## 构建

```bash
swift build
```

## 打包为 .app

```bash
./Scripts/package-app.sh
```

打包完成后，应用会生成在：

```text
.build/app/DesktopAgentPilot.app
```

## 功能

- 打开一个原生 macOS 窗口
- 输入自定义文字
- 点击按钮累计计数
- 一键重置状态
