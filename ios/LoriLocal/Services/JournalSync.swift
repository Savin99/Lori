import Foundation
import UIKit

/// Фоновая отправка строк `Journal` на шлюз Mac mini (`POST /v1/logs`), чтобы
/// разбирать сбои без ручной пересылки `journal.txt` с телефона.
///
/// Принципы:
/// - работает только при настроенном шлюзе (адрес и токен уже в приложении);
/// - буферизует неотправленное на диске (до 512 КБ) и повторяет позже при обрыве;
/// - никогда не пишет в `Journal` о собственных ошибках — цикла записей быть не может;
/// - живёт на своей короткой сессии и не мешает фоновым отправкам расшифровок.
final class JournalSync: @unchecked Sendable {
    static let shared = JournalSync()

    static let outboxLimit = 512 * 1024
    static let chunkLimit = 128 * 1024
    static let initialCatchupLimit = 64 * 1024
    static let catchupKey = "journalSyncInitialCatchupV1"

    struct Endpoint: Sendable {
        let baseURL: URL
        let token: String
    }

    private let queue = DispatchQueue(label: "Lori.journal-sync", qos: .utility)
    private let outboxURL: URL
    private let journalURL: URL
    private let session: URLSession
    private let defaults: UserDefaults
    private let endpointProvider: @Sendable () -> Endpoint?
    private let hasConfiguredBaseURL: @Sendable () -> Bool
    private let build: String
    private let osVersion: String
    private let deviceModel: String
    private let enabled: Bool
    private let debounce: TimeInterval
    private let urgentDebounce: TimeInterval

    private var timer: DispatchSourceTimer?
    private var inFlight = false
    private var consecutiveFailures = 0
    private var backoffUntil: Date = .distantPast
    private var flushWaiters: [@Sendable () -> Void] = []

    init(
        outboxURL: URL = JournalSync.defaultOutboxURL,
        journalURL: URL = Journal.url,
        session: URLSession = JournalSync.defaultSession,
        defaults: UserDefaults = .standard,
        endpointProvider: @escaping @Sendable () -> Endpoint? = JournalSync.defaultEndpoint,
        hasConfiguredBaseURL: (@Sendable () -> Bool)? = nil,
        build: String = JournalSync.defaultBuild,
        osVersion: String = TranscriptionRunway.systemVersion,
        deviceModel: String = JournalSync.machineModel(),
        enabled: Bool = (NSClassFromString("XCTestCase") == nil),
        debounce: TimeInterval = 5,
        urgentDebounce: TimeInterval = 0.5
    ) {
        self.outboxURL = outboxURL
        self.journalURL = journalURL
        self.session = session
        self.defaults = defaults
        self.endpointProvider = endpointProvider
        self.hasConfiguredBaseURL = hasConfiguredBaseURL ?? { GatewaySettings.baseURL != nil }
        self.build = build
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.enabled = enabled
        self.debounce = debounce
        self.urgentDebounce = urgentDebounce
    }

    static var defaultOutboxURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Lori", directoryHint: .isDirectory).appending(path: "journal-outbox.log")
    }

    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private static var defaultBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
    }

    private static func defaultEndpoint() -> Endpoint? {
        guard let baseURL = GatewaySettings.baseURL,
              let token = try? KeychainStore.key(for: .gateway),
              !token.isEmpty else { return nil }
        return Endpoint(baseURL: baseURL, token: token)
    }

    static func machineModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Один раз при первом запуске после обновления подхватывает хвост прежнего
    /// `journal.txt`, чтобы прошлые зависания тоже дошли до Mac mini без пересылки.
    func start() {
        guard enabled else { return }
        queue.sync {
            self.seedInitialCatchupLocked()
        }
        flushNow()
    }

    func enqueue(_ formattedLine: String) {
        guard enabled, hasConfiguredBaseURL(), let data = formattedLine.data(using: .utf8), !data.isEmpty else { return }
        let urgent = Self.isUrgent(formattedLine)
        queue.async {
            self.appendToOutboxLocked(data)
            self.scheduleLocked(delay: urgent ? self.urgentDebounce : self.debounce)
        }
    }

    func flushNow(backgroundTask: Bool = false) {
        guard enabled else { return }
        let finishBackground = backgroundTask ? Self.beginBackgroundGuard() : nil
        queue.async {
            self.backoffUntil = .distantPast
            self.cancelTimerLocked()
            if let finishBackground {
                self.flushWaiters.append(finishBackground)
            }
            self.flushLocked()
        }
    }

    /// Для тестов: дожидается завершения текущей попытки отправки.
    func flushAndWait() async {
        guard enabled else { return }
        await withCheckedContinuation { continuation in
            queue.async {
                self.backoffUntil = .distantPast
                self.cancelTimerLocked()
                self.flushWaiters.append { continuation.resume() }
                self.flushLocked()
            }
        }
    }

    static func isUrgent(_ line: String) -> Bool {
        line.contains("ОШИБКА")
            || line.contains("сбой")
            || line.contains("стоит без движения")
            || line.contains("зависла")
            || line.contains("ждёт сеть")
            || line.contains("перезапустила отправку")
    }

    // MARK: - Очередь и диск (только на `queue`)

    private func seedInitialCatchupLocked() {
        guard !defaults.bool(forKey: Self.catchupKey), hasConfiguredBaseURL() else { return }
        guard let existing = try? Data(contentsOf: journalURL), !existing.isEmpty else {
            defaults.set(true, forKey: Self.catchupKey)
            return
        }
        let tail: Data
        if existing.count > Self.initialCatchupLimit {
            let slice = existing.suffix(Self.initialCatchupLimit)
            if let newline = slice.firstIndex(of: 0x0A) {
                tail = Data(slice[slice.index(after: newline)...])
            } else {
                tail = Data(slice)
            }
        } else {
            tail = existing
        }
        if !tail.isEmpty {
            var batch = Data("[предыдущий журнал устройства до включения автоотправки]\n".utf8)
            batch.append(tail)
            if batch.last != 0x0A { batch.append(0x0A) }
            appendToOutboxLocked(batch)
        }
        defaults.set(true, forKey: Self.catchupKey)
    }

    private func appendToOutboxLocked(_ data: Data) {
        let directory = outboxURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: outboxURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: outboxURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        trimOutboxLocked()
    }

    private func trimOutboxLocked() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: outboxURL.path)[.size] as? Int,
              size > Self.outboxLimit,
              let current = try? Data(contentsOf: outboxURL) else { return }
        let kept = current.suffix(Self.outboxLimit / 2)
        let aligned: Data
        if let newline = kept.firstIndex(of: 0x0A) {
            aligned = Data(kept[kept.index(after: newline)...])
        } else {
            aligned = Data(kept)
        }
        try? aligned.write(to: outboxURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func scheduleLocked(delay: TimeInterval) {
        let now = Date()
        let wait = max(delay, backoffUntil.timeIntervalSince(now))
        cancelTimerLocked()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + max(0.05, wait))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.cancelTimerLocked()
            self.flushLocked()
        }
        timer = source
        source.resume()
    }

    private func cancelTimerLocked() {
        timer?.cancel()
        timer = nil
    }

    private func notifyWaitersLocked() {
        guard !flushWaiters.isEmpty else { return }
        let waiters = flushWaiters
        flushWaiters = []
        for waiter in waiters { waiter() }
    }

    private func flushLocked() {
        guard !inFlight else { return }
        guard Date() >= backoffUntil else {
            scheduleLocked(delay: backoffUntil.timeIntervalSinceNow)
            notifyWaitersLocked()
            return
        }
        guard let endpoint = endpointProvider() else {
            notifyWaitersLocked()
            return
        }
        guard let all = try? Data(contentsOf: outboxURL), !all.isEmpty else {
            notifyWaitersLocked()
            return
        }

        let chunk: Data
        if all.count > Self.chunkLimit {
            let prefix = all.prefix(Self.chunkLimit)
            if let newline = prefix.lastIndex(of: 0x0A) {
                chunk = Data(prefix[...newline])
            } else {
                chunk = Data(prefix)
            }
        } else {
            chunk = all
        }
        let sentCount = chunk.count
        guard sentCount > 0 else {
            notifyWaitersLocked()
            return
        }

        var request = URLRequest(url: endpoint.baseURL.appending(path: "v1/logs"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(build, forHTTPHeaderField: "X-Lori-Build")
        request.setValue(osVersion, forHTTPHeaderField: "X-Lori-iOS")
        request.setValue(deviceModel, forHTTPHeaderField: "X-Lori-Device")
        request.httpBody = chunk

        inFlight = true
        let task = session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            self.queue.async {
                self.inFlight = false
                let status = (response as? HTTPURLResponse)?.statusCode
                if error == nil, let status, (200..<300).contains(status) {
                    self.consecutiveFailures = 0
                    self.backoffUntil = .distantPast
                    let hasMore = self.consumeOutboxLocked(sentBytes: sentCount)
                    if hasMore {
                        self.flushLocked()
                    } else {
                        self.notifyWaitersLocked()
                    }
                } else {
                    self.consecutiveFailures += 1
                    let delay = min(300.0, 15.0 * pow(2.0, Double(min(4, self.consecutiveFailures - 1))))
                    self.backoffUntil = Date().addingTimeInterval(delay)
                    self.scheduleLocked(delay: delay)
                    self.notifyWaitersLocked()
                }
            }
        }
        task.resume()
    }

    /// Удаляет отправленный префикс буфера, сохраняя строки, дописанные за время POST.
    private func consumeOutboxLocked(sentBytes: Int) -> Bool {
        guard let current = try? Data(contentsOf: outboxURL) else { return false }
        if current.count <= sentBytes {
            try? FileManager.default.removeItem(at: outboxURL)
            return false
        }
        let remaining = Data(current.dropFirst(sentBytes))
        try? remaining.write(to: outboxURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return !remaining.isEmpty
    }

    private static func beginBackgroundGuard() -> @Sendable () -> Void {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var rawID: Int = UIBackgroundTaskIdentifier.invalid.rawValue
            private var ended = false

            func start() {
                DispatchQueue.main.async {
                    let id = UIApplication.shared.beginBackgroundTask(withName: "Lori log sync") {
                        self.end()
                    }
                    let shouldEndImmediately = self.lock.withLock { () -> Bool in
                        if self.ended { return true }
                        self.rawID = id.rawValue
                        return false
                    }
                    if shouldEndImmediately, id != .invalid {
                        UIApplication.shared.endBackgroundTask(id)
                    }
                }
            }

            func end() {
                let raw = lock.withLock { () -> Int in
                    guard !ended else { return UIBackgroundTaskIdentifier.invalid.rawValue }
                    ended = true
                    let current = rawID
                    rawID = UIBackgroundTaskIdentifier.invalid.rawValue
                    return current
                }
                guard raw != UIBackgroundTaskIdentifier.invalid.rawValue else { return }
                DispatchQueue.main.async {
                    UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: raw))
                }
            }
        }
        let box = Box()
        box.start()
        return { box.end() }
    }
}
