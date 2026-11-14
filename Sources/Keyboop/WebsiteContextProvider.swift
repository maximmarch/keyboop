import Darwin
import Foundation

/// Состояние активного веб-контекста (KB-001).
enum WebsiteContextStatus: Equatable {
    case notBrowser
    case extensionMissing
    case disconnected
    case unknown
    case internalPage
    case incognitoBlocked
    case active(domain: String, browser: SiteBrowser, windowId: Int?, tabId: Int?)
}

/// Неизменяемый снимок контекста сайта на текущий момент.
struct WebsiteContextSnapshot: Equatable {
    let status: WebsiteContextStatus
    let receivedAt: TimeInterval

    var activeDomain: String? {
        if case .active(let domain, _, _, _) = status { return domain }
        return nil
    }

    var activeBrowser: SiteBrowser? {
        if case .active(_, let browser, _, _) = status { return browser }
        return nil
    }

    var contextIdentityKey: String {
        switch status {
        case .active(let domain, let browser, let windowId, let tabId):
            return "\(browser.rawValue):\(windowId ?? -1):\(tabId ?? -1):\(domain)"
        case .internalPage:
            return "internal"
        case .incognitoBlocked:
            return "incognito"
        case .unknown:
            return "unknown"
        case .disconnected:
            return "disconnected"
        case .extensionMissing:
            return "missing"
        case .notBrowser:
            return "not-browser"
        }
    }
}

enum WebsiteBridgeInstallState: Equatable {
    case installed
    case needsUpdate
    case notInstalled
    case hostMissing
}

extension Notification.Name {
    static let keyboopSiteContextChanged = Notification.Name("keyboopSiteContextChanged")
}

/// Получает события активной вкладки от Chrome Native Messaging Host через локальный Unix-сокет
/// и поддерживает актуальный снимок веб-контекста со сроком годности и без утечки доменов в логи.
final class WebsiteContextProvider {
    static let shared = WebsiteContextProvider()

    static let chromeExtensionID = "pcaljdhkeklgnkmhhjikceedobcealcl"
    static let nativeHostName = "ru.keyboop.site_context"
    private static let contextStaleTTL: TimeInterval = 95.0

    private struct ClientReport: Equatable {
        var browser: SiteBrowser = .chrome
        var focused: Bool = false
        var windowId: Int?
        var tabId: Int?
        var domain: String?
        var isInternal: Bool = false
        var isIncognito: Bool = false
        var updatedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    }

    private final class SocketClient {
        let id: Int
        let fd: Int32
        let source: DispatchSourceRead?
        var buffer = Data()
        var report: ClientReport?

        init(id: Int, fd: Int32, source: DispatchSourceRead?) {
            self.id = id
            self.fd = fd
            self.source = source
        }
    }

    private let queue = DispatchQueue(label: "ru.keyboop.website.context")
    private let lock = NSLock()

    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var staleTimer: DispatchSourceTimer?
    private var nextClientID = 1
    private var clients: [Int: SocketClient] = [:]
    private var lastFocusedClientID: Int?
    private var boundSocketPath: String?

    /// Последний достоверный сайт из активной вкладки браузера (для кнопок быстрого создания правила).
    private var latestKnownActive: (domain: String, browser: SiteBrowser, windowId: Int?, tabId: Int?, at: TimeInterval)?
    private var lastBroadcastIdentity: String = ""

    /// Вызывается на главном потоке при любом изменении активного веб-контекста.
    var onContextChange: (() -> Void)?

    private init() {}

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.sync {
            staleTimer?.cancel()
            staleTimer = nil
            acceptSource?.cancel()
            acceptSource = nil
            serverFD = -1
            for (_, c) in clients {
                c.source?.cancel()
            }
            clients.removeAll()
            if let path = boundSocketPath {
                unlink(path)
                boundSocketPath = nil
            }
        }
    }

    private func startOnQueue() {
        guard serverFD < 0 else { return }

        let path = Self.socketPath()
        let parentDir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        unlink(path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            kbLog("sites: не удалось создать локальный сокет контекста")
            return
        }

        // O_NONBLOCK для accept
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            rawPtr.initializeMemory(as: UInt8.self, repeating: 0)
            for (i, b) in bytes.enumerated() where i < 103 {
                rawPtr[i] = b
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, len)
            }
        }
        guard bindRC == 0 else {
            Darwin.close(fd)
            kbLog("sites: не удалось привязать локальный сокет контекста (errno=\(errno))")
            return
        }

        chmod(path, S_IRUSR | S_IWUSR)
        guard Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            unlink(path)
            kbLog("sites: ошибка listen на локальном сокете (errno=\(errno))")
            return
        }

        serverFD = fd
        boundSocketPath = path

        let acceptSrc = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        acceptSrc.setEventHandler { [weak self] in
            self?.acceptPendingClientsOnQueue()
        }
        acceptSrc.setCancelHandler { [fd] in
            Darwin.close(fd)
        }
        acceptSource = acceptSrc
        acceptSrc.resume()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(15), repeating: .seconds(15))
        timer.setEventHandler { [weak self] in
            self?.evictStaleStateOnQueue()
        }
        staleTimer = timer
        timer.resume()

        kbLog("sites: сервер контекста браузера запущен")
    }

    private func acceptPendingClientsOnQueue() {
        while serverFD >= 0 {
            var storage = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(serverFD, $0, &len)
                }
            }
            if clientFD < 0 {
                break
            }
            let cflags = fcntl(clientFD, F_GETFL)
            if cflags >= 0 { _ = fcntl(clientFD, F_SETFL, cflags | O_NONBLOCK) }

            let cid = nextClientID
            nextClientID += 1
            let src = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
            let client = SocketClient(id: cid, fd: clientFD, source: src)
            src.setEventHandler { [weak self] in
                self?.readFromClientOnQueue(clientID: cid)
            }
            src.setCancelHandler {
                Darwin.close(clientFD)
            }
            clients[cid] = client
            src.resume()

            sendJSON(["type": "status", "keyboopRunning": true], to: client)
            sendJSON(["type": "query"], to: client)
        }
    }

    private func readFromClientOnQueue(clientID: Int) {
        guard let client = clients[clientID] else { return }
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(client.fd, &tmp, tmp.count)
            if n > 0 {
                client.buffer.append(tmp, count: n)
                while let nl = client.buffer.firstIndex(of: 0x0A) {
                    let line = client.buffer.subdata(in: 0..<nl)
                    client.buffer.removeSubrange(0...nl)
                    if !line.isEmpty {
                        handleMessageLineOnQueue(line, from: clientID)
                    }
                }
            } else if n == 0 {
                removeClientOnQueue(clientID)
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                removeClientOnQueue(clientID)
                return
            }
        }
    }

    private func removeClientOnQueue(_ clientID: Int) {
        guard let client = clients.removeValue(forKey: clientID) else { return }
        client.source?.cancel()
        if lastFocusedClientID == clientID {
            lastFocusedClientID = nil
        }
        syncPublishedStateOnQueue()
    }

    private func handleMessageLineOnQueue(_ data: Data, from clientID: Int) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return
        }

        switch type {
        case "hello":
            if let client = clients[clientID] {
                sendJSON(["type": "status", "keyboopRunning": true], to: client)
                sendJSON(["type": "query"], to: client)
            }
            kbLog("sites: подключён native-host расширения (клиентов: \(clients.count))")

        case "bye":
            removeClientOnQueue(clientID)

        case "context":
            guard let client = clients[clientID] else { return }
            let browserID = (obj["browser"] as? String) ?? "chrome"
            let browser = SiteBrowser.from(id: browserID) ?? .chrome
            let focused = (obj["focused"] as? Bool) ?? true
            let windowId = obj["windowId"] as? Int
            let tabId = obj["tabId"] as? Int
            let isInternal = (obj["internal"] as? Bool) ?? false
            let isIncognito = (obj["incognito"] as? Bool) ?? false
            let rawDomain = obj["domain"] as? String
            let normalizedDomain = isInternal ? nil : SiteRuleStore.normalizeObservedDomain(rawDomain)

            let report = ClientReport(
                browser: browser,
                focused: focused,
                windowId: windowId,
                tabId: tabId,
                domain: normalizedDomain,
                isInternal: isInternal,
                isIncognito: isIncognito,
                updatedAt: ProcessInfo.processInfo.systemUptime
            )
            client.report = report
            if focused {
                lastFocusedClientID = clientID
            } else if lastFocusedClientID == clientID {
                lastFocusedClientID = nil
            }
            syncPublishedStateOnQueue()

        default:
            break
        }
    }

    private func evictStaleStateOnQueue() {
        let now = ProcessInfo.processInfo.systemUptime
        var changed = false
        for (cid, client) in clients {
            if let r = client.report, now - r.updatedAt > Self.contextStaleTTL {
                client.report = nil
                if lastFocusedClientID == cid { lastFocusedClientID = nil }
                changed = true
            }
        }
        if changed {
            syncPublishedStateOnQueue()
        }
    }

    private func sendJSON(_ obj: [String: Any], to client: SocketClient) {
        guard client.fd >= 0, var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        _ = data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return 0 }
            return Darwin.write(client.fd, base, data.count)
        }
    }

    /// Запросить у активных клиентов обновление контекста (например, при возврате Chrome на передний план).
    func requestFreshContext() {
        queue.async { [weak self] in
            guard let self else { return }
            for (_, client) in self.clients {
                self.sendJSON(["type": "query"], to: client)
            }
        }
    }

    // MARK: - Reading State

    /// Показывает, подключён ли сейчас хотя бы один native-host от браузерного расширения.
    var isConnected: Bool {
        lock.withLock {
            !clientsIsEmptySnapshot
        }
    }

    private var clientsIsEmptySnapshot = true
    private var currentReportSnapshot: ClientReport?

    private func syncPublishedStateOnQueue() {
        let now = ProcessInfo.processInfo.systemUptime
        let hasClients = !clients.isEmpty

        let chosen: ClientReport? = {
            if let lid = lastFocusedClientID,
               let r = clients[lid]?.report,
               now - r.updatedAt <= Self.contextStaleTTL {
                return r
            }
            let candidates = clients.values.compactMap { $0.report }
                .filter { now - $0.updatedAt <= Self.contextStaleTTL }
            if let focused = candidates.filter(\.focused).max(by: { $0.updatedAt < $1.updatedAt }) {
                return focused
            }
            return candidates.max(by: { $0.updatedAt < $1.updatedAt })
        }()

        let trackIncognito = SiteRuleStore.shared.trackIncognito
        let newIdentity: String = {
            guard hasClients else { return "disconnected" }
            guard let r = chosen else { return "unknown" }
            if r.isIncognito && !trackIncognito { return "incognito" }
            if r.isInternal || r.domain == nil { return "internal" }
            return "\(r.browser.rawValue):\(r.windowId ?? -1):\(r.tabId ?? -1):\(r.domain ?? "")"
        }()

        let changed = lock.withLock { () -> Bool in
            clientsIsEmptySnapshot = !hasClients
            currentReportSnapshot = chosen
            if let r = chosen, !r.isInternal, let dom = r.domain,
               (!r.isIncognito || trackIncognito) {
                latestKnownActive = (dom, r.browser, r.windowId, r.tabId, r.updatedAt)
            } else if !hasClients || (chosen?.isInternal == true) || (chosen?.isIncognito == true && !trackIncognito) {
                latestKnownActive = nil
            }
            if newIdentity != lastBroadcastIdentity {
                lastBroadcastIdentity = newIdentity
                return true
            }
            return false
        }

        if changed {
            DispatchQueue.main.async { [weak self] in
                self?.onContextChange?()
                NotificationCenter.default.post(name: .keyboopSiteContextChanged, object: nil)
            }
        }
    }

    /// Возвращает актуальный снимок веб-контекста для указанного bundleID переднего приложения.
    func snapshot(forBundleID bundleID: String) -> WebsiteContextSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        guard let browser = SiteBrowser.from(bundleID: bundleID) else {
            return WebsiteContextSnapshot(status: .notBrowser, receivedAt: now)
        }

        let (noClients, report) = lock.withLock { (clientsIsEmptySnapshot, currentReportSnapshot) }

        if noClients {
            let state = Self.chromeBridgeInstallState()
            let status: WebsiteContextStatus = (state == .installed) ? .disconnected : .extensionMissing
            return WebsiteContextSnapshot(status: status, receivedAt: now)
        }

        guard let r = report, now - r.updatedAt <= Self.contextStaleTTL else {
            return WebsiteContextSnapshot(status: .unknown, receivedAt: now)
        }

        if r.browser != browser {
            return WebsiteContextSnapshot(status: .unknown, receivedAt: r.updatedAt)
        }

        if r.isIncognito && !SiteRuleStore.shared.trackIncognito {
            return WebsiteContextSnapshot(status: .incognitoBlocked, receivedAt: r.updatedAt)
        }

        if r.isInternal || r.domain == nil {
            return WebsiteContextSnapshot(status: .internalPage, receivedAt: r.updatedAt)
        }

        return WebsiteContextSnapshot(
            status: .active(domain: r.domain!, browser: r.browser, windowId: r.windowId, tabId: r.tabId),
            receivedAt: r.updatedAt
        )
    }

    /// Возвращает последний свежий домен Chrome для быстрого создания правила из меню или Настроек.
    func activeSiteForQuickAdd() -> (domain: String, browser: SiteBrowser)? {
        let now = ProcessInfo.processInfo.systemUptime
        return lock.withLock {
            guard !clientsIsEmptySnapshot,
                  let info = latestKnownActive,
                  now - info.at <= Self.contextStaleTTL else {
                return nil
            }
            return (info.domain, info.browser)
        }
    }

    /// Для тестов: имитирует входящее сообщение от моста без реального сокета.
    func injectTestMessage(_ jsonData: Data, clientID: Int = 1) {
        queue.sync {
            if clients[clientID] == nil {
                let client = SocketClient(id: clientID, fd: -1, source: nil)
                clients[clientID] = client
            }
            handleMessageLineOnQueue(jsonData, from: clientID)
        }
    }

    func clearTestClients() {
        queue.sync {
            for (_, c) in clients {
                c.source?.cancel()
            }
            clients.removeAll()
            lastFocusedClientID = nil
            syncPublishedStateOnQueue()
        }
    }

    // MARK: - Bridge & Extension Paths

    static func socketPath() -> String {
        let fm = FileManager.default
        let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = appSup.appendingPathComponent("Keyboop", isDirectory: true)
        let isDev = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
        let filename = isDev ? "site-context-dev.sock" : "site-context.sock"
        let p = dir.appendingPathComponent(filename).path
        if p.utf8.count < 100 { return p }
        return "/tmp/ru.keyboop.\(getuid()).\(isDev ? "dev" : "prod").sock"
    }

    static func nativeHostExecutableURL() -> URL? {
        let candidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/KeyboopNativeHost")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    static func extensionDirectoryURL() -> URL? {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("Extensions/chrome", isDirectory: true),
           FileManager.default.fileExists(atPath: res.appendingPathComponent("manifest.json").path) {
            return res
        }
        // Dev fallback рядом с исходниками, если запускается бинарник без пересборки ресурсов
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Extensions/chrome", isDirectory: true)
        if FileManager.default.fileExists(atPath: local.appendingPathComponent("manifest.json").path) {
            return local
        }
        return nil
    }

    static func chromeNativeMessagingManifestURLs() -> [URL] {
        let fm = FileManager.default
        let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let primary = appSup
            .appendingPathComponent("Google/Chrome/NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent("\(nativeHostName).json")

        var urls = [primary]
        for variant in ["Google/Chrome Beta", "Google/Chrome Canary"] {
            let base = appSup.appendingPathComponent(variant, isDirectory: true)
            if fm.fileExists(atPath: base.path) {
                urls.append(
                    base.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
                        .appendingPathComponent("\(nativeHostName).json")
                )
            }
        }
        return urls
    }

    static func chromeBridgeInstallState() -> WebsiteBridgeInstallState {
        guard let hostURL = nativeHostExecutableURL() else {
            return .hostMissing
        }
        guard let manifestURL = chromeNativeMessagingManifestURLs().first,
              let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .notInstalled
        }
        let path = json["path"] as? String
        let origins = json["allowed_origins"] as? [String] ?? []
        let expectedOrigin = "chrome-extension://\(chromeExtensionID)/"
        if path == hostURL.path && origins.contains(expectedOrigin) {
            return .installed
        }
        return .needsUpdate
    }

    @discardableResult
    static func installChromeNativeBridge() throws -> [URL] {
        guard let hostURL = nativeHostExecutableURL() else {
            throw NSError(
                domain: "ru.keyboop.sitecontext",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "KeyboopNativeHost executable not found in app bundle"]
            )
        }
        let payload: [String: Any] = [
            "name": nativeHostName,
            "description": "Keyboop native messaging bridge for per-site input rules",
            "path": hostURL.path,
            "type": "stdio",
            "allowed_origins": [
                "chrome-extension://\(chromeExtensionID)/"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])

        var written: [URL] = []
        let fm = FileManager.default
        for url in chromeNativeMessagingManifestURLs() {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            written.append(url)
        }
        kbLog("sites: установлен Native Messaging мост для Google Chrome")
        return written
    }
}
