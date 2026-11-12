import Cocoa
import WebKit
import UniformTypeIdentifiers

let fileExt = "ideaboard"

// Hidden screenshot mode (for the README): --shot board.ideaboard out.png [--host]
// Uses its own settings domain so it never touches the real app's name, device ID or open file.
let shotArgs: (board: String, out: String)? = {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: "--shot"), i + 2 < a.count else { return nil }
    return (a[i + 1], a[i + 2])
}()
let appDefaults: UserDefaults = {
    guard shotArgs != nil, let d = UserDefaults(suiteName: "com.lemonspitz.ideaboard.shots") else { return .standard }
    d.set("Alex", forKey: "displayName")
    return d
}()

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                         WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var ready = false
    var pendingOpen: URL?
    var dirty = false { didSet { window?.isDocumentEdited = dirty; appDefaults.set(dirty, forKey: "dirty") } }
    var fileURL: URL? {
        didSet {
            appDefaults.set(fileURL?.path, forKey: "lastFile")
            updateTitle()
        }
    }

    lazy var supportDir: URL = {
        let d = ProcessInfo.processInfo.environment["IDEABOARD_SUPPORT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Idea Board", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    var autosaveURL: URL { supportDir.appendingPathComponent("autosave.\(fileExt)") }
    var boardType: UTType { UTType(filenameExtension: fileExt) ?? .json }

    // MARK: launch

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()

        let uc = WKUserContentController()
        uc.add(self, name: "board")
        var boot = "window.__IDEABOARD_NATIVE=true;"
        // Remembered collaboration identity: a random per-install device ID (never a hardware ID)
        // and a display name that defaults to the Mac account's first name.
        let ud = appDefaults
        var device = ud.string(forKey: "deviceID") ?? ""
        if device.isEmpty { device = UUID().uuidString.lowercased(); ud.set(device, forKey: "deviceID") }
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        var ident: [String: String] = ["id": device, "defaultName": first.isEmpty ? NSUserName() : first]
        if let n = ud.string(forKey: "displayName"), !n.isEmpty { ident["name"] = n }
        if let d = try? JSONSerialization.data(withJSONObject: ident), let js = String(data: d, encoding: .utf8) {
            boot += "window.__IDEABOARD_DEVICE=\(js);"
        }
        if let s = try? String(contentsOf: autosaveURL, encoding: .utf8) {
            boot += "window.__IDEABOARD_INITIAL=\(jsString(s));"
            if appDefaults.bool(forKey: "dirty") { boot += "window.__IDEABOARD_DIRTY=true;" }
            if let p = appDefaults.string(forKey: "lastFile"), FileManager.default.fileExists(atPath: p) {
                fileURL = URL(fileURLWithPath: p)
            }
        }
        uc.addUserScript(WKUserScript(source: boot, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let cfg = WKWebViewConfiguration()
        cfg.userContentController = uc
        // A live session must keep running when the window is in the background or minimised;
        // by default WebKit throttles/suspends inactive pages, which stalls peer connections.
        if #available(macOS 14.0, *) { cfg.preferences.inactiveSchedulingPolicy = .none }
        web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.allowsMagnification = false
        web.setValue(false, forKey: "drawsBackground")

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 480)
        window.contentView = web
        window.delegate = self
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName("IdeaBoardMain")
        if shotArgs != nil { window.setContentSize(NSSize(width: 1440, height: 900)); window.center() }
        updateTitle()
        window.makeKeyAndOrderFront(nil)

        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        NSApp.activate(ignoringOtherApps: true)

        // Hidden check used by build tests: --selftest prints board state then quits.
        if CommandLine.arguments.contains("--selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.selfTest() }
        }
        // --selftest-join CODE: join a live session as a guest, report what arrived, quit.
        if let i = CommandLine.arguments.firstIndex(of: "--selftest-join"), i + 1 < CommandLine.arguments.count {
            let code = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.joinTest(code) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func application(_ app: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if url.scheme?.lowercased() == "ideaboard" {
            // ideaboard://join/CODE
            let code = url.pathComponents.last(where: { $0 != "/" }) ?? url.host ?? ""
            if ready { join(code) } else { pendingJoin = code }
            return
        }
        if ready { confirmDiscard { self.openURL(url) } } else { pendingOpen = url }
    }

    var pendingJoin: String?
    var liveActivity: NSObjectProtocol?
    var sessionRole = ""

    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
        ready = true
        if let u = pendingOpen { pendingOpen = nil; openURL(u) }
        if let c = pendingJoin { pendingJoin = nil; join(c) }
        if let shot = shotArgs { runShot(board: shot.board, out: shot.out) }
    }

    /// Joining a live board replaces the open board, like Open… does.
    func join(_ code: String) {
        confirmDiscard {
            self.fileURL = nil
            self.dirty = false
            self.web.callAsyncJavaScript("app.join(code, true)", arguments: ["code": code], in: nil, in: .page) { _ in }
        }
    }

    @objc func shareSession(_ s: Any?) { js("app.openShare()") }

    // Image button in the page uses <input type=file>.
    func webView(_ w: WKWebView, runOpenPanelWith p: WKOpenPanelParameters, initiatedByFrame f: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = p.allowsMultipleSelection
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: window) { r in completionHandler(r == .OK ? panel.urls : nil) }
    }

    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = m
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    // MARK: bridge

    func userContentController(_ uc: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "autosave":
            if let d = body["data"] as? String { try? d.write(to: autosaveURL, atomically: true, encoding: .utf8) }
        case "dirty": dirty = body["value"] as? Bool ?? false
        case "save": save(nil)
        case "saveAs": saveAs(nil)
        case "open": openDocument(nil)
        case "new": newDocument(nil)
        case "export": exportPNG(nil)
        case "name": updateTitle()
        case "join": if let c = body["code"] as? String { join(c) }
        case "session":
            sessionRole = body["value"] as? String ?? ""
            updateTitle()
            // Keep App Nap away while hosting or joining a live session.
            if sessionRole.isEmpty {
                if let a = liveActivity { ProcessInfo.processInfo.endActivity(a); liveActivity = nil }
            } else if liveActivity == nil {
                liveActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Live collaboration session")
            }
        case "identity":
            if let n = body["name"] as? String, !n.isEmpty { appDefaults.set(n, forKey: "displayName") }
        case "copy":
            if let v = body["value"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(v, forType: .string)
            }
        default: break
        }
    }

    func js(_ code: String, _ done: ((Any?) -> Void)? = nil) {
        web.evaluateJavaScript(code) { r, err in
            if let err = err { NSLog("IdeaBoard JS error: \(err)") }
            done?(r)
        }
    }

    // MARK: documents

    func updateTitle() {
        guard let window = window else { return }
        if let u = fileURL {
            window.title = u.deletingPathExtension().lastPathComponent
            window.representedURL = u
        } else {
            window.title = "Idea Board"
            window.representedURL = nil
        }
    }

    func confirmDiscard(_ then: @escaping () -> Void) {
        guard dirty else { then(); return }
        let a = NSAlert()
        a.messageText = "Save changes to this board?"
        a.informativeText = "Your changes will be lost if you don't save them."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Don't Save")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { r in
            switch r {
            case .alertFirstButtonReturn: self.save(nil, then: then)
            case .alertSecondButtonReturn: then()
            default: break
            }
        }
    }

    @objc func newDocument(_ s: Any?) {
        confirmDiscard {
            self.fileURL = nil
            self.js("app.newBoard()")
        }
    }

    @objc func openDocument(_ s: Any?) {
        confirmDiscard {
            let p = NSOpenPanel()
            p.allowedContentTypes = [self.boardType, .json]
            p.beginSheetModal(for: self.window) { r in
                if r == .OK, let u = p.url { self.openURL(u) }
            }
        }
    }

    func openURL(_ url: URL) {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else {
            NSAlert(error: NSError(domain: "IdeaBoard", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't read \(url.lastPathComponent)."])).runModal()
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        web.callAsyncJavaScript("return app.load(data, name)", arguments: ["data": s, "name": name],
                                in: nil, in: .page) { r in
            if case .success(let ok) = r, (ok as? Bool) == true {
                self.fileURL = url
                self.dirty = false
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                self.js("app.markSaved(null)")
            }
        }
    }

    @objc func save(_ s: Any?) { save(s, then: nil) }

    func save(_ s: Any?, then: (() -> Void)?) {
        if let u = fileURL { write(to: u, then: then) } else { saveAs(s, then: then) }
    }

    @objc func saveAs(_ s: Any?) { saveAs(s, then: nil) }

    func saveAs(_ s: Any?, then: (() -> Void)?) {
        js("app.name()") { r in
            let p = NSSavePanel()
            p.allowedContentTypes = [self.boardType]
            p.nameFieldStringValue = ((r as? String) ?? "Untitled board") + "." + fileExt
            p.beginSheetModal(for: self.window) { resp in
                if resp == .OK, let u = p.url { self.write(to: u, then: then) }
            }
        }
    }

    func write(to url: URL, then: (() -> Void)?) {
        js("app.serialize()") { r in
            guard let s = r as? String else { return }
            do {
                try s.write(to: url, atomically: true, encoding: .utf8)
                self.fileURL = url
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                let name = url.deletingPathExtension().lastPathComponent
                self.web.callAsyncJavaScript("app.markSaved(name)", arguments: ["name": name], in: nil, in: .page) { _ in }
                self.dirty = false
                then?()
            } catch {
                NSAlert(error: error).beginSheetModal(for: self.window)
            }
        }
    }

    @objc func exportPNG(_ s: Any?) {
        js("app.exportPNG()") { r in
            guard let d = r as? String, let comma = d.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(d[d.index(after: comma)...])) else {
                let a = NSAlert(); a.messageText = "Nothing to export yet"
                a.informativeText = "Add something to the board first."
                a.beginSheetModal(for: self.window); return
            }
            self.js("app.name()") { n in
                let p = NSSavePanel()
                p.allowedContentTypes = [.png]
                p.nameFieldStringValue = ((n as? String) ?? "Board") + ".png"
                p.beginSheetModal(for: self.window) { resp in
                    if resp == .OK, let u = p.url {
                        do { try data.write(to: u) } catch { NSAlert(error: error).runModal() }
                    }
                }
            }
        }
    }

    func windowShouldClose(_ w: NSWindow) -> Bool { true }

    // MARK: menu actions forwarded to the page

    @objc func undoBoard(_ s: Any?) { js("app.undo()") }
    @objc func redoBoard(_ s: Any?) { js("app.redo()") }
    @objc func selectAllBoard(_ s: Any?) { js("app.selectAll()") }
    @objc func deleteBoard(_ s: Any?) { js("app.deleteSelection()") }
    @objc func duplicateBoard(_ s: Any?) { js("app.duplicate()") }
    @objc func zoomInBoard(_ s: Any?) { js("app.zoomIn()") }
    @objc func zoomOutBoard(_ s: Any?) { js("app.zoomOut()") }
    @objc func zoomResetBoard(_ s: Any?) { js("app.zoomReset()") }
    @objc func zoomFitBoard(_ s: Any?) { js("app.fit()") }
    @objc func gridBoard(_ s: Any?) { js("app.toggleGrid()") }

    func buildMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title); items.forEach { m.addItem($0) }; it.submenu = m; return it
        }
        func item(_ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.keyEquivalentModifierMask = mods; return i
        }
        let appName = "Idea Board"
        main.addItem(sub(appName, [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.perform(NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu")
        recentMenu.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        recent.submenu = recentMenu
        main.addItem(sub("File", [
            item("New Board", #selector(newDocument(_:)), "n"),
            item("Open…", #selector(openDocument(_:)), "o"),
            recent,
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save", #selector(save(_:) as (Any?) -> Void), "s"),
            item("Save As…", #selector(saveAs(_:) as (Any?) -> Void), "s", [.command, .shift]),
            .separator(),
            item("Export as PNG…", #selector(exportPNG(_:)), "e"),
            .separator(),
            item("Work Together Live…", #selector(shareSession(_:)), "l", [.command, .shift]),
        ]))
        main.addItem(sub("Edit", [
            item("Undo", #selector(undoBoard(_:)), "z"),
            item("Redo", #selector(redoBoard(_:)), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Duplicate", #selector(duplicateBoard(_:)), "d"),
            item("Delete", #selector(deleteBoard(_:))),
            item("Select All", #selector(selectAllBoard(_:)), "a"),
        ]))
        main.addItem(sub("View", [
            item("Zoom In", #selector(zoomInBoard(_:)), "="),
            item("Zoom Out", #selector(zoomOutBoard(_:)), "-"),
            item("Actual Size", #selector(zoomResetBoard(_:)), "0"),
            item("Zoom to Fit", #selector(zoomFitBoard(_:)), "1"),
            .separator(),
            item("Show/Hide Grid", #selector(gridBoard(_:)), "'"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        let win = sub("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        main.addItem(win)
        NSApp.mainMenu = main
        NSApp.windowsMenu = win.submenu
    }

    // MARK: self test

    func runShot(board: String, out: String) {
        let env = ProcessInfo.processInfo.environment
        let host = CommandLine.arguments.contains("--host")
        openURL(URL(fileURLWithPath: board))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.js("app.fit(); 1")
            if host { self.js("document.querySelector('#sharebtn').click(); document.querySelector('[data-s=host]').click(); 1") }
        }
        if host {
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                self.js("app._state().code") { r in print("SHOTCODE \(r ?? "nil")"); fflush(stdout) }
            }
        }
        let wait = Double(env["IDEABOARD_SHOT_WAIT"] ?? "") ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            self.js(env["IDEABOARD_SHOT_JS"] ?? "1") { r in
                print("SHOTJS \(r ?? "nil")"); fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.web.takeSnapshot(with: nil) { img, _ in
                        if let img = img, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
                           let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: out))
                            print("SHOT saved \(out) \(rep.pixelsWide)x\(rep.pixelsHigh)"); fflush(stdout)
                        }
                        self.js("app.leaveSession(); 1") { _ in NSApp.terminate(nil) }
                    }
                }
            }
        }
    }

    func joinTest(_ code: String) {
        print("JOINTEST start")
        js("typeof RTCPeerConnection") { r in print(" RTCPeerConnection: \(r ?? "nil")") }
        web.callAsyncJavaScript("app.join(code, true)", arguments: ["code": code], in: nil, in: .page) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            self.js("JSON.stringify(app._state().live) + ' ' + app._state().role + ' ' + JSON.stringify(app._state().people) + ' items=' + app._state().items.length") { r in
                print("JOINTEST \(r ?? "nil")")
                // Leave a visible mark on the shared board, then hold the cursor still for a screenshot.
                self.js("document.querySelector('#stage').dispatchEvent(new MouseEvent('dblclick', {bubbles:true, clientX: 500, clientY: 420}))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.js("document.execCommand('insertText', false, 'Hello from the Mac app'); document.activeElement.blur(); 1")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.js("app.leaveSession()") { _ in NSApp.terminate(nil) }
                    }
                }
            }
        }
    }

    func selfTest() {
        let code = """
        app.newBoard();
        document.querySelector('#menubtn').click();
        document.querySelector('[data-m="tpl:Flowchart"]').click();
        const s = app._state();
        return JSON.stringify({ items: s.items.length, conns: s.items.filter(i => i.type === 'connector').length,
                                png: (app.exportPNG() || '').length, native: !!window.__IDEABOARD_NATIVE });
        """
        web.callAsyncJavaScript(code, arguments: [:], in: nil, in: .page) { r in
            switch r {
            case .success(let v): print("SELFTEST \(v)")
            case .failure(let e): print("SELFTEST FAILED \(e)")
            }
            if let out = ProcessInfo.processInfo.environment["IDEABOARD_SHOT"] {
                self.web.takeSnapshot(with: nil) { img, _ in
                    if let img = img, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: out))
                    }
                    self.js("app.newBoard()") { _ in NSApp.terminate(nil) }
                }
            } else {
                self.js("app.newBoard()") { _ in NSApp.terminate(nil) }
            }
        }
    }
}

func jsString(_ s: String) -> String {
    let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
    return String(data: data, encoding: .utf8) ?? "\"\""
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
