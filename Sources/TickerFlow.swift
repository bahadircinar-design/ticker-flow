// Ticker Flow — native macOS shell around the node-based analysis workbench.
// The workbench UI lives in Resources/index.html; this file supplies the window,
// menus, document files, CSV import/export and live price downloads.

import Cocoa
import WebKit
import UniformTypeIdentifiers

let workflowType = UTType(exportedAs: "com.bahacinar.tickerflow.workflow", conformingTo: .json)

@main
struct TickerFlowLauncher {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                         WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {

    private var window: NSWindow!
    private var web: WKWebView!
    private var pageReady = false
    private var pendingOpen: URL?
    private var currentDoc = ""
    private let defaults = UserDefaults.standard

    private let templates: [(key: String, title: String)] = [
        ("trend", "Trend Follower"),
        ("revert", "Mean Reversion"),
        ("risk", "Risk & Robustness"),
        ("quality", "Quality + Momentum"),
        ("blank", "Blank Canvas"),
    ]

    private let allowedHosts: Set<String> = [
        "query1.finance.yahoo.com", "query2.finance.yahoo.com", "stooq.com", "stooq.pl",
    ]

    private var docURL: URL? {
        didSet {
            defaults.set(docURL?.path, forKey: "docPath")
            updateTitle()
        }
    }

    private var dirty = false {
        didSet {
            defaults.set(dirty, forKey: "dirty")
            window?.isDocumentEdited = dirty
        }
    }

    private lazy var supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Ticker Flow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var autosaveURL: URL { supportDir.appendingPathComponent("autosave.tickerflow") }

    private var displayName: String {
        docURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        makeWindow()
        if let path = defaults.string(forKey: "docPath"), FileManager.default.fileExists(atPath: path) {
            docURL = URL(fileURLWithPath: path)
        } else {
            docURL = nil
        }
        dirty = defaults.bool(forKey: "dirty")
        loadPage()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if pageReady {
            openDocument(at: url, confirm: true)
        } else {
            pendingOpen = url
        }
    }

    private func makeWindow() {
        let config = WKWebViewConfiguration()
        let content = WKUserContentController()
        content.addScriptMessageHandler(self, contentWorld: .page, name: "native")
        content.addUserScript(WKUserScript(source: bootScript(),
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true))
        config.userContentController = content

        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.allowsMagnification = false
        web.alphaValue = 0
        if #available(macOS 13.3, *) {
            web.isInspectable = true
        }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered,
                          defer: false)
        window.minSize = NSSize(width: 980, height: 620)
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = web
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("TickerFlowMainWindow")
        updateTitle()
    }

    /// Runs before the page's own script: flags the native bridge and restores the last session.
    private func bootScript() -> String {
        var js = "window.TF_NATIVE = true; window.TF_DIRTY = \(defaults.bool(forKey: "dirty") ? "true" : "false");"
        if let data = try? Data(contentsOf: autosaveURL),
           (try? JSONSerialization.jsonObject(with: data)) != nil,
           let text = String(data: data, encoding: .utf8) {
            js += "window.TF_AUTOSAVE = \(text);"
        }
        return js
    }

    private func loadPage() {
        guard let resources = Bundle.main.resourceURL else { return }
        web.loadFileURL(resources.appendingPathComponent("index.html"), allowingReadAccessTo: resources)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        web.alphaValue = 1
        if let url = pendingOpen {
            pendingOpen = nil
            openDocument(at: url, confirm: true)
        }
    }

    // MARK: - Messages from the page

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            replyHandler(nil, "Malformed message")
            return
        }
        switch cmd {
        case "get":
            guard let url = body["url"] as? String else {
                replyHandler(nil, "Missing address")
                return
            }
            httpGet(url, reply: replyHandler)
        case "changed":
            if let doc = body["doc"] as? String {
                currentDoc = doc
                try? doc.write(to: autosaveURL, atomically: true, encoding: .utf8)
            }
            if let isDirty = body["dirty"] as? Bool {
                dirty = isDirty
            }
            replyHandler(nil, nil)
        case "template":
            replyHandler(nil, nil)
            loadTemplate((body["key"] as? String) ?? "blank")
        default:
            replyHandler(nil, "Unknown command \(cmd)")
        }
    }

    private func httpGet(_ address: String, reply: @escaping (Any?, String?) -> Void) {
        guard let url = URL(string: address), let host = url.host, allowedHosts.contains(host) else {
            reply(nil, "That address isn't one of Ticker Flow's price providers.")
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/csv, text/plain, */*", forHTTPHeaderField: "Accept")
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                reply(["status": status, "text": String(decoding: data, as: UTF8.self)], nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    // MARK: - Running JavaScript

    private func callJS(_ expression: String, _ args: [String: Any] = [:], done: ((Any?) -> Void)? = nil) {
        web.callAsyncJavaScript("return " + expression, arguments: args, in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                done?(value)
            case .failure(let error):
                NSLog("Ticker Flow JS error: \(error.localizedDescription)")
                done?(nil)
            }
        }
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
            menuItem.keyEquivalentModifierMask = mods
            menuItem.target = target
            return menuItem
        }
        func add(_ menu: NSMenu) {
            let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
        }

        // App menu
        let appMenu = NSMenu(title: "Ticker Flow")
        appMenu.addItem(item("About Ticker Flow", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide Ticker Flow", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Ticker Flow", #selector(NSApplication.terminate(_:)), "q"))
        add(appMenu)

        // File
        let file = NSMenu(title: "File")
        file.addItem(item("New Workflow", #selector(newWorkflow(_:)), "n", target: self))
        file.addItem(item("Open…", #selector(openWorkflow(_:)), "o", target: self))
        file.addItem(.separator())
        file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        file.addItem(item("Save", #selector(saveWorkflow(_:)), "s", target: self))
        file.addItem(item("Save As…", #selector(saveWorkflowAs(_:)), "s", [.command, .shift], target: self))
        file.addItem(.separator())
        file.addItem(item("Import Price CSV…", #selector(importCSV(_:)), "i", target: self))
        file.addItem(item("Export Results as CSV…", #selector(exportResults(_:)), "e", [.command, .shift], target: self))
        add(file)

        // Edit (needed for copy/paste in text fields)
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        add(edit)

        // Templates
        let tpl = NSMenu(title: "Templates")
        for (index, template) in templates.enumerated() {
            let menuItem = item(template.title, #selector(templateChosen(_:)), "\(index + 1)", target: self)
            menuItem.representedObject = template.key
            tpl.addItem(menuItem)
        }
        add(tpl)

        // View
        let view = NSMenu(title: "View")
        view.addItem(item("Refresh Prices", #selector(refreshPrices(_:)), "r", target: self))
        view.addItem(.separator())
        view.addItem(item("Fit Workflow", #selector(fitView(_:)), "0", target: self))
        view.addItem(item("Zoom In", #selector(zoomIn(_:)), "=", target: self))
        view.addItem(item("Zoom Out", #selector(zoomOut(_:)), "-", target: self))
        add(view)

        // Window
        let win = NSMenu(title: "Window")
        win.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        win.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        win.addItem(.separator())
        win.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = win
        add(win)

        return main
    }

    // MARK: - Menu actions

    @objc func newWorkflow(_ sender: Any?) {
        guard confirmDiscard() else { return }
        callJS("TF.newDoc()")
        docURL = nil
        dirty = false
    }

    @objc func templateChosen(_ sender: NSMenuItem) {
        loadTemplate((sender.representedObject as? String) ?? "blank")
    }

    private func loadTemplate(_ key: String) {
        guard confirmDiscard() else { return }
        callJS("TF.loadTemplate(k)", ["k": key])
        docURL = nil
        dirty = false
    }

    @objc func openWorkflow(_ sender: Any?) {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [workflowType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openDocument(at: url, confirm: false)
    }

    private func openDocument(at url: URL, confirm: Bool) {
        if confirm && !confirmDiscard() { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            showError("Couldn't open “\(url.lastPathComponent)”", "The file couldn't be read as text.")
            return
        }
        callJS("TF.loadDoc(t)", ["t": text]) { [weak self] result in
            guard let self else { return }
            if let message = result as? String, !message.isEmpty {
                self.showError("Couldn't open “\(url.lastPathComponent)”", message)
                return
            }
            self.docURL = url
            self.dirty = false
        }
    }

    @objc func saveWorkflow(_ sender: Any?) {
        save(showPanel: docURL == nil)
    }

    @objc func saveWorkflowAs(_ sender: Any?) {
        save(showPanel: true)
    }

    @discardableResult
    private func save(showPanel: Bool) -> Bool {
        guard !currentDoc.isEmpty else {
            showError("Nothing to save yet", "Wait for the workflow to finish loading, then try again.")
            return false
        }
        var target = docURL
        if showPanel || target == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [workflowType]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = displayName + ".tickerflow"
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            target = url
        }
        guard let url = target else { return false }
        do {
            try prettyJSON(currentDoc).write(to: url, atomically: true, encoding: .utf8)
            docURL = url
            dirty = false
            callJS("TF.markSaved()")
            return true
        } catch {
            showError("Couldn't save the workflow", error.localizedDescription)
            return false
        }
    }

    @objc func importCSV(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose daily prices with Date, Open, High, Low, Close and Volume columns."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            showError("Couldn't read “\(url.lastPathComponent)”", "The file isn't plain text.")
            return
        }
        callJS("TF.importCSV(n, t)", ["n": url.deletingPathExtension().lastPathComponent, "t": text])
    }

    @objc func exportResults(_ sender: Any?) {
        callJS("TF.exportResults()") { [weak self] value in
            guard let self else { return }
            guard let result = value as? [String: Any], let csv = result["csv"] as? String else {
                self.showError("Nothing to export yet", "Wire some research criteria or tests into the workflow first.")
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = (result["name"] as? String) ?? "Ticker Flow results.csv"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.showError("Couldn't export the results", error.localizedDescription)
            }
        }
    }

    @objc func refreshPrices(_ sender: Any?) { callJS("TF.refresh()") }
    @objc func fitView(_ sender: Any?) { callJS("TF.fit()") }
    @objc func zoomIn(_ sender: Any?) { callJS("TF.zoomIn()") }
    @objc func zoomOut(_ sender: Any?) { callJS("TF.zoomOut()") }

    // MARK: - File input inside the page (CSV node's “Choose File” button)

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            completionHandler(panel.urls)
        } else {
            completionHandler(nil)
        }
    }

    // MARK: - Helpers

    private func confirmDiscard() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes to “\(displayName)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don't Save")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return save(showPanel: docURL == nil)
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    private func prettyJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let output = String(data: pretty, encoding: .utf8) else { return text }
        return output
    }

    private func updateTitle() {
        guard let window else { return }
        window.title = displayName
        window.subtitle = "Ticker Flow"
        window.representedURL = docURL
    }

    private func showError(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
