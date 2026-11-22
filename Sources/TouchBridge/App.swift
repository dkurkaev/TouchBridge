import AppKit
import ServiceManagement

final class LogWindowController: NSWindowController, NSWindowDelegate {
    private let textView: NSTextView
    private var listener: UUID?
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "TouchBridge — лог"
        window.setFrameAutosaveName("TouchBridgeLog")

        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isRichText = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        textView = tv

        let clear = NSButton(title: "Очистить", target: nil, action: nil)
        let openFile = NSButton(title: "Открыть файл лога", target: nil, action: nil)
        let copy = NSButton(title: "Копировать всё", target: nil, action: nil)
        let buttons = NSStackView(views: [clear, copy, openFile])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let root = NSStackView(views: [scroll, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
        ])

        super.init(window: window)
        window.delegate = self
        clear.target = self; clear.action = #selector(clearLog)
        openFile.target = self; openFile.action = #selector(openLogFile)
        copy.target = self; copy.action = #selector(copyAll)

        textView.string = LogSink.shared.lines.joined(separator: "\n") + "\n"
        listener = LogSink.shared.addListener { [weak self] line in self?.append(line) }
        scrollToEnd()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func append(_ line: String) {
        guard let storage = textView.textStorage else { return }
        let atBottom = (textView.enclosingScrollView?.verticalScroller?.floatValue ?? 1) > 0.98
        storage.append(NSAttributedString(string: line + "\n",
                                          attributes: [.font: font, .foregroundColor: NSColor.textColor]))
        if storage.length > 600_000 { storage.deleteCharacters(in: NSRange(location: 0, length: 200_000)) }
        if atBottom { scrollToEnd() }
    }

    private func scrollToEnd() { textView.scrollToEndOfDocument(nil) }

    @objc private func clearLog() { LogSink.shared.clear(); textView.string = "" }
    @objc private func openLogFile() { NSWorkspace.shared.open(LogSink.shared.fileURL) }
    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    func windowWillClose(_ notification: Notification) {
        if let l = listener { LogSink.shared.removeListener(l) }
        listener = nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let bridge = Bridge(configPath: Config.defaultPath)
    private var logWindow: LogWindowController?
    private var permTimer: Timer?
    private let micButton = DictationButton()
    private var dictationButton: Bool {
        get { defaults.bool(forKey: "dictationButton") }
        set { defaults.set(newValue, forKey: "dictationButton") }
    }
    private let defaults = UserDefaults.standard

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    private var verbose: Bool {
        get { defaults.object(forKey: "verbose") as? Bool ?? false } // debugging only
        set { defaults.set(newValue, forKey: "verbose") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        bridge.micButton = micButton
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeft
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        bridge.verbose = verbose
        bridge.onFingers = { [weak self] n in self?.statusItem.button?.title = n > 0 ? " \(n)" : "" }

        tlog("TouchBridge запущен (\(Bundle.main.bundlePath))")
        if !FileManager.default.fileExists(atPath: Config.defaultPath) {
            try? Config.writeDefaults(to: Config.defaultPath)
        }
        Permissions.logStatus()
        if !Permissions.inputMonitoring { Permissions.requestInputMonitoring() }
        if !Permissions.accessibility { Permissions.requestAccessibility() }
        if !Permissions.all { showLog() }

        tryStart()
        updateIcon()
        micButton.onHideRequested = { [weak self] in self?.setDictationButton(false) }
        if dictationButton { micButton.show() }
        // Pick up permissions granted later without a restart.
        permTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.tryStart()
            self?.updateIcon()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        micButton.hide() // also ends the dictation log helper
        bridge.stop()
    }

    private func tryStart() {
        guard enabled, !bridge.running else { return }
        // Never seize the touchscreen unless we can also post events — otherwise touch would just die.
        guard Permissions.all else { return }
        bridge.start()
    }

    private func updateIcon() {
        let symbol: String
        if !Permissions.all { symbol = "exclamationmark.triangle" }
        else if bridge.running { symbol = "hand.tap.fill" }
        else { symbol = "hand.tap" }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TouchBridge")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let im = Permissions.inputMonitoring, ax = Permissions.accessibility

        let status: String
        if !im || !ax { status = "⚠️ Не хватает разрешений — сенсор не захвачен" }
        else if bridge.running {
            let dev = bridge.deviceNames.first ?? "жду сенсорный экран…"
            status = "● Работает: \(dev)"
        } else { status = "○ Выключено" }
        menu.addItem(disabled(status))
        if bridge.running, let d = bridge.displayName { menu.addItem(disabled("    дисплей: \(d)")) }
        menu.addItem(.separator())

        menu.addItem(item((im ? "✅" : "❌") + " Мониторинг ввода" + (im ? "" : " — выдать…"), #selector(fixInput)))
        menu.addItem(item((ax ? "✅" : "❌") + " Универсальный доступ" + (ax ? "" : " — выдать…"), #selector(fixAX)))
        menu.addItem(.separator())

        let toggle = item(enabled ? "Выключить" : "Включить", #selector(toggleEnabled), key: "e")
        menu.addItem(toggle)
        let kb = item("Экранная клавиатура", #selector(toggleKeyboard), key: "k")
        kb.state = OnScreenKeyboard.isVisible ? .on : .off
        menu.addItem(kb)
        let mic = item("Кнопка диктовки", #selector(toggleDictationButton), key: "d")
        mic.state = dictationButton ? .on : .off
        menu.addItem(mic)
        menu.addItem(.separator())

        menu.addItem(item("Открыть настройки (config.json)", #selector(openConfig), key: ","))
        menu.addItem(item("Применить настройки", #selector(reloadConfig), key: "r"))
        let login = item("Запускать при входе в систему", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        // Everything for debugging lives in its own submenu.
        let debugMenu = NSMenu()
        debugMenu.addItem(item("Показать лог", #selector(showLogAction), key: "l"))
        let v = item("Подробный лог", #selector(toggleVerbose))
        v.state = verbose ? .on : .off
        debugMenu.addItem(v)
        debugMenu.addItem(.separator())
        for (key, title) in Tester.names {
            let t = item("Проверка: " + title, #selector(runTest(_:)))
            t.representedObject = key
            debugMenu.addItem(t)
        }
        debugMenu.addItem(.separator())
        debugMenu.addItem(item("Режим наблюдения (сырые касания) — 15 с", #selector(monitor)))
        let debug = NSMenuItem(title: "Отладка", action: nil, keyEquivalent: "")
        debug.submenu = debugMenu
        menu.addItem(debug)
        menu.addItem(.separator())
        menu.addItem(item("Выйти", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    // MARK: Actions

    @objc private func fixInput() {
        Permissions.requestInputMonitoring()
        Permissions.openSettings("Privacy_ListenEvent")
        tlog("Включи TouchBridge в «Мониторинг ввода». Если macOS попросит перезапуск — согласись.")
    }

    @objc private func fixAX() {
        Permissions.requestAccessibility()
        Permissions.openSettings("Privacy_Accessibility")
        tlog("Включи TouchBridge в «Универсальный доступ».")
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        if enabled {
            if !Permissions.all { tlog("Не могу включить: не хватает разрешений"); showLog() }
            tryStart()
        } else {
            bridge.stop()
        }
        updateIcon()
    }

    @objc private func toggleVerbose() {
        verbose.toggle()
        bridge.verbose = verbose
        if bridge.running { bridge.restart() }
    }

    @objc private func showLogAction() { showLog() }

    @objc private func toggleDictationButton() { setDictationButton(!dictationButton) }

    private func setDictationButton(_ on: Bool) {
        dictationButton = on
        if on { micButton.show() } else { micButton.hide() }
        tlog(on ? "Кнопка диктовки показана: тап — диктовка в поле с курсором, перетаскивание — переместить"
                : "Кнопка диктовки убрана")
    }

    @objc private func toggleKeyboard() {
        // Off the main thread: it drives the Input menu through Accessibility (≈0.3 s).
        DispatchQueue.global(qos: .userInitiated).async { OnScreenKeyboard.toggle() }
    }

    private func showLog() {
        if logWindow == nil || logWindow?.window?.isVisible == false { logWindow = LogWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        logWindow?.showWindow(nil)
        logWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func runTest(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        showLog()
        Tester.run(name, config: bridge.config)
    }

    @objc private func monitor() {
        showLog()
        let wasRunning = bridge.running
        bridge.stop()
        tlog("Режим наблюдения: касайся экрана 1…5 пальцами 15 секунд")
        bridge.start(inject: false, seize: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }
            self.bridge.stop()
            if wasRunning || self.enabled { self.tryStart() }
            self.updateIcon()
        }
    }

    @objc private func openConfig() {
        if !FileManager.default.fileExists(atPath: Config.defaultPath) {
            try? Config.writeDefaults(to: Config.defaultPath)
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: Config.defaultPath)],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
        tlog("После правки конфига нажми «Применить настройки» (⌘R в меню)")
    }

    @objc private func reloadConfig() {
        tlog("Перечитываю настройки…")
        if bridge.running { bridge.restart() } else { tryStart() }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                tlog("Автозапуск выключен")
            } else {
                try SMAppService.mainApp.register()
                tlog("Автозапуск включён")
            }
        } catch {
            tlog("⚠️  Автозапуск: \(error.localizedDescription)")
        }
    }

    @objc private func quit() {
        bridge.stop()
        NSApp.terminate(nil)
    }
}
