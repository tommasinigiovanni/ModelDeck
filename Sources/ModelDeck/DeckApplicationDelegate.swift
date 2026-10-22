import AppKit
import SwiftUI
import Combine
import ModelDeckCore

@MainActor final class DeckApplicationDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store: DeckStore
    private(set) var statusItem: NSStatusItem?
    private(set) var popover = NSPopover()
    private var dashboard: NSWindow?
    private var settings: NSWindow?
    private var subscription: AnyCancellable?

    init(store: DeckStore) { self.store = store }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        configureStatusItem()
        showDashboard()
        store.start()
    }
    private func configureMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu(); appItem.submenu = app
        app.addItem(withTitle: "Impostazioni…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Nascondi ModelDeck", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Esci da ModelDeck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(title: "Modifica", action: nil, keyEquivalent: ""); main.addItem(editItem)
        let edit = NSMenu(title: "Modifica"); editItem.submenu = edit
        for (title, selector, key) in [("Taglia", #selector(NSText.cut(_:)), "x"), ("Copia", #selector(NSText.copy(_:)), "c"), ("Incolla", #selector(NSText.paste(_:)), "v"), ("Seleziona tutto", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        let windowItem = NSMenuItem(title: "Finestra", action: nil, keyEquivalent: ""); main.addItem(windowItem)
        let windows = NSMenu(title: "Finestra"); windowItem.submenu = windows
        windows.addItem(withTitle: "Chiudi", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windows.addItem(withTitle: "Riduci a icona", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.mainMenu = main; NSApp.windowsMenu = windows
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showDashboard(); return true }

    func configureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "ModelDeck")
        image?.isTemplate = true; image?.size = NSSize(width: 17, height: 18)
        item.button?.image = image; item.button?.toolTip = "ModelDeck"
        item.button?.target = self; item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        popover.behavior = .transient; popover.animates = false; popover.delegate = self
        popover.contentSize = NSSize(width: 420, height: 680)
        let panel = MenuPanel(openDashboard: { [weak self] in self?.showDashboard() },
                              openProcesses: { [weak self] in self?.showDashboard(section: "processes") },
                              openSettings: { [weak self] in self?.showSettings() })
        popover.contentViewController = NSHostingController(rootView: panel.environmentObject(store).environment(\.locale, Locale(identifier: "it_IT")))
        subscription = store.$snapshot.sink { [weak self] snapshot in
            self?.statusItem?.button?.toolTip = "ModelDeck · CPU \(DeckFormat.percent(snapshot.cpu)) · RAM \(DeckFormat.percent(snapshot.memoryPercent))"
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            let menu = NSMenu()
            for (title, selector) in [("Apri cruscotto", #selector(openDashboardAction)), ("Processi", #selector(openProcessesAction)), ("Impostazioni…", #selector(openSettingsAction)), ("Esci da ModelDeck", #selector(quitAction))] {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); popover.contentViewController?.view.window?.makeKey() }
    }
    @objc private func openDashboardAction() { showDashboard() }
    @objc private func openProcessesAction() { showDashboard(section: "processes") }
    @objc private func openSettingsAction() { showSettings() }
    @objc private func quitAction() { NSApp.terminate(nil) }

    func showDashboard(section: String? = nil) {
        popover.performClose(nil)
        if dashboard == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 1000), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "ModelDeck"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 940, height: 700)
            window.center(); dashboard = window
            setDashboardContent(section: section ?? "overview")
        } else if let section { setDashboardContent(section: section) }
        dashboard?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func setDashboardContent(section: String) {
        dashboard?.contentViewController = NSHostingController(rootView: Dashboard(initialSection: section).environmentObject(store).environment(\.locale, Locale(identifier: "it_IT")))
    }
    func showSettings() {
        popover.performClose(nil)
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 800), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Impostazioni · ModelDeck"; window.isReleasedWhenClosed = false; window.center()
            window.contentViewController = NSHostingController(rootView: ScrollView { SettingsView().padding(24) }.background(DeckTheme.background).foregroundStyle(DeckTheme.foreground).environmentObject(store).deckAppearance())
            settings = window
        }
        settings?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func checkMenuLifecycle() -> [String: Bool] {
        togglePopover()
        let opened = popover.isShown
        togglePopover()
        let closed = !popover.isShown
        dashboard?.close()
        showDashboard()
        return ["template_icon": statusItem?.button?.image?.isTemplate == true,
                "button_target": statusItem?.button?.target === self,
                "popover_opened": opened, "popover_closed": closed,
                "dashboard_reopened": dashboard?.isVisible == true]
    }
}
