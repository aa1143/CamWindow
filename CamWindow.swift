// CamWindow.swift
// 悬浮摄像头窗口：只截取画面中间部分（不变形），始终置顶，可无边框
// 所有设置：右键点击画面；设置自动保存
// 打包：bash build.sh

import Cocoa
import AVFoundation

// MARK: - 选项

struct Ratio {
    let name: String; let w: CGFloat; let h: CGFloat
    init(_ name: String, _ w: CGFloat, _ h: CGFloat) { self.name = name; self.w = w; self.h = h }
}
let ratios = [Ratio("3:4", 3, 4), Ratio("9:16", 9, 16), Ratio("1:1", 1, 1),
              Ratio("4:3", 4, 3), Ratio("16:9（原始画面）", 16, 9)]
let corners: [(String, Double)] = [("直角", 0), ("小圆角", 8), ("中圆角", 14), ("大圆角", 24)]

// MARK: - 设置（自动保存）

enum Settings {
    static let d = UserDefaults.standard
    static var ratioIndex: Int {
        get { d.object(forKey: "ratio") as? Int ?? 0 }
        set { d.set(newValue, forKey: "ratio") }
    }
    static var corner: Double {
        get { d.object(forKey: "corner") as? Double ?? 14 }
        set { d.set(newValue, forKey: "corner") }
    }
    static var showTitleBar: Bool {
        get { d.object(forKey: "titlebar") as? Bool ?? false }
        set { d.set(newValue, forKey: "titlebar") }
    }
    static var mirrored: Bool {
        get { d.object(forKey: "mirror") as? Bool ?? true }
        set { d.set(newValue, forKey: "mirror") }
    }
    static var onTop: Bool {
        get { d.object(forKey: "ontop") as? Bool ?? true }
        set { d.set(newValue, forKey: "ontop") }
    }
    static var title: String {
        get { d.string(forKey: "title") ?? "Human 👶" }
        set { d.set(newValue, forKey: "title") }
    }
    static var cameraID: String? {
        get { d.string(forKey: "camera") }
        set { d.set(newValue, forKey: "camera") }
    }
}

// MARK: - 窗口

class CamPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { NSApp.terminate(nil) }   // Esc 退出
        else { super.keyDown(with: event) }
    }
}

// MARK: - 摄像头画面

class CameraView: NSView {
    weak var controller: Controller?
    let session = AVCaptureSession()
    let previewLayer: AVCaptureVideoPreviewLayer
    var currentDeviceID: String?

    override init(frame: NSRect) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill     // 裁切填满，不拉伸
        previewLayer.backgroundColor = NSColor.black.cgColor
        super.init(frame: frame)
        // 容器层负责圆角裁切，摄像头画面作为子层放在里面
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        if #available(macOS 10.15, *) { layer?.cornerCurve = .continuous }
        previewLayer.frame = bounds
        layer?.addSublayer(previewLayer)
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
    }

    required init?(coder: NSCoder) { fatalError() }

    // 窗口大小变化时，让画面层跟着铺满（关掉动画避免拖动时画面滞后）
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    func setCornerRadius(_ r: CGFloat) {
        layer?.cornerRadius = r
        layer?.masksToBounds = true
    }

    override var mouseDownCanMoveWindow: Bool { true }

    // 滚轮 / 触控板上下滑：等比缩放，保持中心不动
    override func scrollWheel(with event: NSEvent) {
        guard let w = window, let c = controller else { return }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        let cur = w.contentRect(forFrameRect: w.frame)
        let newW = max(120, min(1600, cur.width + step))
        let newH = c.height(for: newW)
        let rect = NSRect(x: cur.midX - newW / 2, y: cur.midY - newH / 2, width: newW, height: newH)
        w.setFrame(w.frameRect(forContentRect: rect), display: true)
        w.invalidateShadow()
    }

    static func devices() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types += [.external, .continuityCamera]
        } else {
            types.append(.externalUnknown)
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video,
                                                position: .unspecified).devices
    }

    func start(deviceID: String?) {
        switchTo(deviceID: deviceID)
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    func switchTo(deviceID: String?) {
        var device: AVCaptureDevice? = nil
        if let id = deviceID { device = AVCaptureDevice(uniqueID: id) }
        if device == nil { device = AVCaptureDevice.default(for: .video) }
        guard let dev = device, let input = try? AVCaptureDeviceInput(device: dev) else {
            print("找不到可用的摄像头")
            return
        }
        session.beginConfiguration()
        for old in session.inputs { session.removeInput(old) }
        if session.canAddInput(input) {
            session.addInput(input)
            currentDeviceID = dev.uniqueID
        }
        session.commitConfiguration()
        applyMirror()
    }

    func applyMirror() {
        if let conn = previewLayer.connection, conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = Settings.mirrored
        }
    }
}

// MARK: - 控制器

class Controller: NSObject, NSApplicationDelegate {
    var window: CamPanel!
    var camView: CameraView!

    var ratio: Ratio { ratios[min(max(Settings.ratioIndex, 0), ratios.count - 1)] }
    func height(for width: CGFloat) -> CGFloat { (width / ratio.w * ratio.h).rounded() }

    func styleMask() -> NSWindow.StyleMask {
        Settings.showTitleBar ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless, .resizable]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 360, height: height(for: 360))
        window = CamPanel(contentRect: rect, styleMask: styleMask(), backing: .buffered, defer: false)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = true

        camView = CameraView(frame: rect)
        camView.controller = self
        window.contentView = camView

        if !window.setFrameUsingName("CamWindow") { window.center() }
        window.setFrameAutosaveName("CamWindow")       // 记住位置和大小

        applyChrome()
        applyRatio()
        applyOnTop()
        refreshMenus()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                if granted {
                    self.camView.start(deviceID: Settings.cameraID)
                    self.refreshMenus()
                } else {
                    print("没有摄像头权限：系统设置 → 隐私与安全性 → 摄像头")
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: 应用设置

    func applyChrome() {
        let content = window.contentRect(forFrameRect: window.frame)
        window.styleMask = styleMask()
        let borderless = !Settings.showTitleBar
        window.isOpaque = !borderless
        window.backgroundColor = borderless ? .clear : .black
        window.isMovableByWindowBackground = borderless
        window.title = Settings.title
        window.setFrame(window.frameRect(forContentRect: content), display: true)
        applyCorner()
    }

    func applyRatio() {
        window.contentAspectRatio = NSSize(width: ratio.w, height: ratio.h)
        window.contentMinSize = NSSize(width: 120, height: height(for: 120))
        let c = window.contentRect(forFrameRect: window.frame)
        let newH = height(for: c.width)
        let rect = NSRect(x: c.minX, y: c.maxY - newH, width: c.width, height: newH)   // 左上角不动
        window.setFrame(window.frameRect(forContentRect: rect), display: true)
        window.invalidateShadow()
    }

    func applyCorner() {
        camView.setCornerRadius(Settings.showTitleBar ? 0 : CGFloat(Settings.corner))
        camView.needsDisplay = true
        window.display()
        window.invalidateShadow()      // 让阴影跟着圆角形状更新
    }

    func applyOnTop() {
        window.level = Settings.onTop ? .floating : .normal
    }

    // MARK: 菜单

    func makeItem(_ title: String, _ action: Selector, on: Bool = false, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        item.isEnabled = enabled
        return item
    }

    func buildSettingsMenu(includeQuit: Bool) -> NSMenu {
        let m = NSMenu(title: "设置")
        m.autoenablesItems = false

        let ratioMenu = NSMenu()
        ratioMenu.autoenablesItems = false
        for (i, r) in ratios.enumerated() {
            let it = makeItem(r.name, #selector(setRatio(_:)), on: i == Settings.ratioIndex)
            it.tag = i
            ratioMenu.addItem(it)
        }
        let ratioItem = NSMenuItem(title: "画面比例", action: nil, keyEquivalent: "")
        ratioItem.submenu = ratioMenu
        m.addItem(ratioItem)

        let cornerMenu = NSMenu()
        cornerMenu.autoenablesItems = false
        for (i, c) in corners.enumerated() {
            let it = makeItem(c.0, #selector(setCorner(_:)), on: c.1 == Settings.corner,
                              enabled: !Settings.showTitleBar)
            it.tag = i
            cornerMenu.addItem(it)
        }
        let cornerItem = NSMenuItem(title: Settings.showTitleBar ? "圆角（无边框时可用）" : "圆角",
                                    action: nil, keyEquivalent: "")
        cornerItem.submenu = cornerMenu
        m.addItem(cornerItem)

        let camMenu = NSMenu()
        camMenu.autoenablesItems = false
        let devices = CameraView.devices()
        if devices.isEmpty {
            camMenu.addItem(makeItem("没有找到摄像头", #selector(noop(_:)), enabled: false))
        }
        for dev in devices {
            let it = makeItem(dev.localizedName, #selector(setCamera(_:)), on: dev.uniqueID == camView.currentDeviceID)
            it.representedObject = dev.uniqueID
            camMenu.addItem(it)
        }
        let camItem = NSMenuItem(title: "摄像头", action: nil, keyEquivalent: "")
        camItem.submenu = camMenu
        m.addItem(camItem)

        m.addItem(.separator())
        m.addItem(makeItem("显示标题栏", #selector(toggleTitleBar(_:)), on: Settings.showTitleBar))
        m.addItem(makeItem("镜像画面", #selector(toggleMirror(_:)), on: Settings.mirrored))
        m.addItem(makeItem("始终置顶", #selector(toggleOnTop(_:)), on: Settings.onTop))
        m.addItem(.separator())
        m.addItem(makeItem("修改窗口标题…", #selector(editTitle(_:))))
        m.addItem(makeItem("恢复默认大小", #selector(resetSize(_:))))

        if includeQuit {
            m.addItem(.separator())
            let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            quit.target = NSApp
            m.addItem(quit)
        }
        return m
    }

    func refreshMenus() {
        camView.menu = buildSettingsMenu(includeQuit: true)     // 右键菜单

        let main = NSMenu()                                     // 顶部菜单栏
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 CamWindow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let setItem = NSMenuItem()
        setItem.submenu = buildSettingsMenu(includeQuit: false)
        main.addItem(setItem)
        NSApp.mainMenu = main
    }

    // MARK: 菜单动作

    @objc func noop(_ sender: NSMenuItem) {}

    @objc func setRatio(_ sender: NSMenuItem) {
        Settings.ratioIndex = sender.tag
        applyRatio(); refreshMenus()
    }

    @objc func setCorner(_ sender: NSMenuItem) {
        Settings.corner = corners[sender.tag].1
        applyCorner(); refreshMenus()
    }

    @objc func setCamera(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.cameraID = id
        camView.switchTo(deviceID: id)
        refreshMenus()
    }

    @objc func toggleTitleBar(_ sender: NSMenuItem) {
        Settings.showTitleBar.toggle()
        applyChrome(); applyRatio(); refreshMenus()
    }

    @objc func toggleMirror(_ sender: NSMenuItem) {
        Settings.mirrored.toggle()
        camView.applyMirror(); refreshMenus()
    }

    @objc func toggleOnTop(_ sender: NSMenuItem) {
        Settings.onTop.toggle()
        applyOnTop(); refreshMenus()
    }

    @objc func editTitle(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "窗口标题"
        alert.informativeText = "显示在标题栏上（打开「显示标题栏」后可见）"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = Settings.title
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            Settings.title = field.stringValue
            window.title = field.stringValue
        }
    }

    @objc func resetSize(_ sender: NSMenuItem) {
        let c = window.contentRect(forFrameRect: window.frame)
        let w: CGFloat = 360, h = height(for: 360)
        let rect = NSRect(x: c.midX - w / 2, y: c.midY - h / 2, width: w, height: h)
        window.setFrame(window.frameRect(forContentRect: rect), display: true)
        window.invalidateShadow()
    }
}

// MARK: - 启动

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
