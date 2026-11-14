import Darwin
import Foundation

// Prevent SIGPIPE from killing the host when the local socket closes mid-write.
signal(SIGPIPE, SIG_IGN)

enum NativeBridge {
    private static let maxMessageBytes = 1024 * 1024
    private static let stdoutQueue = DispatchQueue(label: "ru.keyboop.nativehost.stdout")
    private static let socketQueue = DispatchQueue(label: "ru.keyboop.nativehost.socket")

    private static var sockFD: Int32 = -1
    private static var readSource: DispatchSourceRead?
    private static var lastSentPayload: Data?
    private static var incomingBuffer = Data()

    static func run() -> Never {
        // Periodically try reconnecting if Keyboop wasn't open when Chrome started the host.
        let timer = DispatchSource.makeTimerSource(queue: socketQueue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler {
            if sockFD < 0 {
                _ = ensureConnected()
            }
        }
        timer.resume()

        // Try immediate initial connection.
        socketQueue.sync {
            _ = ensureConnected()
        }

        // Read Native Messaging frames synchronously from Chrome stdin.
        DispatchQueue.global(qos: .userInitiated).async {
            readStdinLoop()
        }

        dispatchMain()
    }

    private static func owningBundleIdentifier() -> String? {
        guard let execPath = Bundle.main.executablePath else { return nil }
        let execURL = URL(fileURLWithPath: execPath).resolvingSymlinksInPath()
        // Expected layout: Keyboop.app/Contents/Helpers/KeyboopNativeHost
        let contentsURL = execURL.deletingLastPathComponent().deletingLastPathComponent()
        let plistURL = contentsURL.appendingPathComponent("Info.plist")
        guard let dict = NSDictionary(contentsOf: plistURL),
              let bid = dict["CFBundleIdentifier"] as? String else {
            return nil
        }
        return bid
    }

    private static func candidateSocketPaths() -> [String] {
        if let testSock = ProcessInfo.processInfo.environment["KEYBOOP_NATIVE_HOST_SOCKET"], !testSock.isEmpty {
            return [testSock]
        }
        let fm = FileManager.default
        let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = appSup.appendingPathComponent("Keyboop", isDirectory: true)

        func resolved(_ filename: String, tmpTag: String) -> String {
            let p = dir.appendingPathComponent(filename).path
            if p.utf8.count < 100 { return p }
            return "/tmp/ru.keyboop.\(getuid()).\(tmpTag).sock"
        }

        let devPath = resolved("site-context-dev.sock", tmpTag: "dev")
        let prodPath = resolved("site-context.sock", tmpTag: "prod")

        if owningBundleIdentifier()?.hasSuffix(".dev") == true {
            return [devPath, prodPath]
        }
        return [prodPath, devPath]
    }

    @discardableResult
    private static func ensureConnected() -> Bool {
        if sockFD >= 0 { return true }
        for path in candidateSocketPaths() {
            guard path.utf8.count < 104 else { continue }
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }

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
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, len)
                }
            }
            if rc == 0 {
                sockFD = fd
                incomingBuffer.removeAll(keepingCapacity: true)
                startSocketReader(fd: fd)
                sendHelloAndReplayLast()
                writeToChromeJSON(["type": "status", "keyboopRunning": true])
                return true
            }
            Darwin.close(fd)
        }
        return false
    }

    private static func startSocketReader(fd: Int32) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: socketQueue)
        src.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 {
                disconnectSocket()
                return
            }
            incomingBuffer.append(buf, count: n)
            while let nl = incomingBuffer.firstIndex(of: 0x0A) {
                let line = incomingBuffer.subdata(in: 0..<nl)
                incomingBuffer.removeSubrange(0...nl)
                if !line.isEmpty {
                    writeToChrome(data: line)
                }
            }
        }
        src.setCancelHandler {
            Darwin.close(fd)
        }
        readSource = src
        src.resume()
    }

    private static func disconnectSocket() {
        readSource?.cancel()
        readSource = nil
        sockFD = -1
        incomingBuffer.removeAll(keepingCapacity: true)
        writeToChromeJSON(["type": "status", "keyboopRunning": false])
    }

    private static func sendHelloAndReplayLast() {
        let hello: [String: Any] = ["type": "hello", "hostPid": Int(getpid())]
        if let d = try? JSONSerialization.data(withJSONObject: hello) {
            _ = sendLineOnSocket(d)
        }
        if let last = lastSentPayload {
            _ = sendLineOnSocket(last)
        }
    }

    private static func sendLineOnSocket(_ payload: Data) -> Bool {
        guard sockFD >= 0 else { return false }
        var line = payload
        line.append(0x0A)
        let ok = line.withUnsafeBytes { rawBuf -> Bool in
            guard let base = rawBuf.baseAddress else { return false }
            var sent = 0
            while sent < line.count {
                let n = Darwin.write(sockFD, base.advanced(by: sent), line.count - sent)
                if n <= 0 {
                    return false
                }
                sent += n
            }
            return true
        }
        if !ok {
            disconnectSocket()
        }
        return ok
    }

    private static func readExactStdin(_ count: Int) -> Data? {
        var out = Data(capacity: count)
        var buf = [UInt8](repeating: 0, count: min(count, 65536))
        while out.count < count {
            let need = min(buf.count, count - out.count)
            let n = Darwin.read(STDIN_FILENO, &buf, need)
            if n == 0 { return nil }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            out.append(buf, count: n)
        }
        return out
    }

    private static func readStdinLoop() -> Never {
        while true {
            guard let lenData = readExactStdin(4) else {
                socketQueue.sync {
                    if sockFD >= 0,
                       let bye = try? JSONSerialization.data(withJSONObject: ["type": "bye"]) {
                        _ = sendLineOnSocket(bye)
                    }
                }
                exit(0)
            }
            let length = lenData.withUnsafeBytes { $0.load(as: UInt32.self) }
            guard length > 0, Int(length) <= maxMessageBytes else {
                exit(1)
            }
            guard let body = readExactStdin(Int(length)) else {
                exit(0)
            }
            // Strip any embedded newlines from single-line socket framing.
            let compact = compactSingleLineJSON(body) ?? body
            socketQueue.async {
                lastSentPayload = compact
                if ensureConnected() {
                    _ = sendLineOnSocket(compact)
                } else {
                    writeToChromeJSON(["type": "status", "keyboopRunning": false])
                }
            }
        }
    }

    private static func compactSingleLineJSON(_ data: Data) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let compact = try? JSONSerialization.data(withJSONObject: obj) else {
            return nil
        }
        return compact
    }

    private static func writeToChromeJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        writeToChrome(data: data)
    }

    private static func writeToChrome(data: Data) {
        stdoutQueue.async {
            var len = UInt32(data.count)
            let header = Data(bytes: &len, count: 4)
            _ = writeAllStdout(header)
            _ = writeAllStdout(data)
        }
    }

    private static func writeAllStdout(_ data: Data) -> Bool {
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return false }
            var sent = 0
            while sent < data.count {
                let n = Darwin.write(STDOUT_FILENO, base.advanced(by: sent), data.count - sent)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                sent += n
            }
            return true
        }
    }
}

NativeBridge.run()
