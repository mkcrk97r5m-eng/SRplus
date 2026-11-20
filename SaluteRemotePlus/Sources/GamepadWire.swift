import Foundation
import Network
import Security
import CommonCrypto
import CryptoKit

/// Конфигурация UDP-канала пульта Salute TV (`gamepad`, порт 6801).
/// Базовый профиль (.baseline) точно соответствует официальному протоколу Салют:
/// UDP · AES-256-CBC/PKCS7 · AES(BE32(order) + Protobuf3) · IV = 16 байт UUID(sessionId) ·
/// обязательный пакет Introduction (field 21, apiVersion "1.7.2") + keepalive Ping (field 15) раз в 500 мс.
struct WireConfig: Codable, Equatable {
    enum Transport: String, Codable, CaseIterable { case udp, tcp }

    enum CipherMode: String, Codable, CaseIterable {
        case cbc
        case gcm
        case ecb

        var title: String {
            switch self {
            case .cbc: return "AES-CBC"
            case .gcm: return "AES-GCM"
            case .ecb: return "AES-ECB"
            }
        }
    }

    enum Framing: String, Codable, CaseIterable {
        case encOrder
        case rawEnc
        case orderEnc
        case lenOrderEnc
        case lenEncOrder

        var hasLength: Bool { self == .lenOrderEnc || self == .lenEncOrder }
        var title: String {
            switch self {
            case .encOrder: return "AES(order+msg)"
            case .rawEnc: return "AES(msg)"
            case .orderEnc: return "order|AES(msg)"
            case .lenOrderEnc: return "len|order|AES"
            case .lenEncOrder: return "len|AES(order+msg)"
            }
        }
    }

    enum KeyMode: String, Codable, CaseIterable { case auto, base64, hex, utf8 }

    enum IVMode: String, Codable, CaseIterable {
        case uuidBytes
        case prefixedRandom
        case utf8Lower
        case zero

        var title: String {
            switch self {
            case .uuidBytes: return "uuid"
            case .prefixedRandom: return "iv+enc"
            case .utf8Lower: return "utf8-low"
            case .zero: return "zero"
            }
        }
    }

    enum PayloadMode: String, Codable, CaseIterable {
        case protoBool
        case protoAction
        case protoFlat
        case protoFlatAction

        var title: String {
            switch self {
            case .protoBool: return "Salute pb3"
            case .protoAction: return "pb:0/1"
            case .protoFlat: return "flat:1/0"
            case .protoFlatAction: return "flat:0/1"
            }
        }
    }

    var transport: Transport = .udp
    var cipher: CipherMode = .cbc
    var framing: Framing = .encOrder
    var keyMode: KeyMode = .auto
    var ivMode: IVMode = .uuidBytes
    var payloadMode: PayloadMode = .protoBool

    init(
        transport: Transport = .udp,
        cipher: CipherMode = .cbc,
        framing: Framing = .encOrder,
        keyMode: KeyMode = .auto,
        ivMode: IVMode = .uuidBytes,
        payloadMode: PayloadMode = .protoBool
    ) {
        self.transport = transport
        self.cipher = cipher
        self.framing = framing
        self.keyMode = keyMode
        self.ivMode = ivMode
        self.payloadMode = payloadMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transport = try c.decodeIfPresent(Transport.self, forKey: .transport) ?? .udp
        cipher = try c.decodeIfPresent(CipherMode.self, forKey: .cipher) ?? .cbc
        framing = try c.decodeIfPresent(Framing.self, forKey: .framing) ?? .encOrder
        keyMode = try c.decodeIfPresent(KeyMode.self, forKey: .keyMode) ?? .auto
        ivMode = try c.decodeIfPresent(IVMode.self, forKey: .ivMode) ?? .uuidBytes
        payloadMode = try c.decodeIfPresent(PayloadMode.self, forKey: .payloadMode) ?? .protoBool
    }

    /// Официальный протокол Salute TV.
    static let baseline = WireConfig()
    private static let storeKey = "SaluteRemotePlus.wireConfig.v3"

    var title: String {
        let ivLabel = cipher == .ecb ? "none" : ivMode.title
        return "\(transport.rawValue.uppercased()) · \(cipher.title) · \(framing.title) · iv:\(ivLabel) · \(payloadMode.title)"
    }

    static func candidates(for session: GamepadSession) -> [WireConfig] {
        guard GamepadWire.deriveKey(session.aesKey, .auto) != nil else { return [] }
        var result: [WireConfig] = [.baseline]

        let extras: [WireConfig] = [
            WireConfig(transport: .udp, cipher: .cbc, framing: .encOrder, keyMode: .auto, ivMode: .utf8Lower, payloadMode: .protoBool),
            WireConfig(transport: .udp, cipher: .cbc, framing: .encOrder, keyMode: .auto, ivMode: .zero, payloadMode: .protoBool),
            WireConfig(transport: .udp, cipher: .cbc, framing: .orderEnc, keyMode: .auto, ivMode: .uuidBytes, payloadMode: .protoBool),
            WireConfig(transport: .udp, cipher: .gcm, framing: .encOrder, keyMode: .auto, ivMode: .uuidBytes, payloadMode: .protoBool),
            WireConfig(transport: .udp, cipher: .gcm, framing: .rawEnc, keyMode: .auto, ivMode: .prefixedRandom, payloadMode: .protoBool),
        ]
        for cfg in extras where !result.contains(cfg) {
            result.append(cfg)
        }
        return result
    }

    static func load() -> WireConfig {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let config = try? JSONDecoder().decode(WireConfig.self, from: data) else { return .baseline }
        return config
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: storeKey) }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storeKey)
    }
}

final class GamepadWire: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var handshakeConfirmed = false
    @Published private(set) var config = WireConfig.load()

    private static let clientName = "SaluteRemotePlus"
    private static let gamepadApiVersion = "1.7.2"

    private let queue = DispatchQueue(label: "SaluteRemotePlus.GamepadWire")
    private var connection: NWConnection?
    private var session: GamepadSession?
    private var cfg = WireConfig.load()
    private var key: Data?
    private var staticIV: Data?

    private enum OutboundPayload {
        case introduction(sessionId: String)
        case button(code: UInt32, pressed: Bool)
        case keyboardSignal(keyCode: Int32, pressed: Bool)
        case keyboardSymbols(text: String)
        case launchApp(signal: UInt32, packageName: String)

        var logLabel: String {
            switch self {
            case .introduction: return "Introduction"
            case .button(let code, let pressed): return "Button \(code) \(pressed ? "↓" : "↑")"
            case .keyboardSignal(let keyCode, let pressed): return "Key \(keyCode) \(pressed ? "↓" : "↑")"
            case .keyboardSymbols(let text): return "Symbols(\(text.count) симв.)"
            case .launchApp(_, let pkg): return "LaunchApp(\(pkg))"
            }
        }
    }

    private struct PendingEvent {
        let payload: OutboundPayload
        let delayAfter: TimeInterval
    }

    private var hosts: [String] = []
    private var hostIndex = 0
    private var pending: [PendingEvent] = []
    private var sendInFlight = false
    private var delayWorkItem: DispatchWorkItem?
    private var pingTimer: DispatchSourceTimer?
    private var introRetryWorkItem: DispatchWorkItem?
    private var introAcked = false
    private var order: UInt32 = 0
    private var lastServerOrder: Int32 = -1
    private var generation = 0
    private var sentLogged = 0
    private var transportReady = false
    private var openCompletion: ((Bool) -> Void)?
    private var isProbing = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0
    private let maxReconnectAttempts = 2

    /// Вызывается на main-потоке, если локальные попытки переподключения исчерпаны.
    var onReconnectNeeded: (() -> Void)?

    func prepare(session: GamepadSession) {
        queue.async {
            if let current = self.session,
               current.sessionId == session.sessionId,
               current.port == session.port,
               current.serviceVersion == session.serviceVersion,
               current.aesKey == session.aesKey,
               current.ipv4 == session.ipv4,
               self.transportReady,
               self.connection != nil,
               self.key != nil {
                self.startPingTimerLocked(generation: self.generation)
                return
            }

            self.isProbing = false
            self.reconnectAttempt = 0
            self.teardownLocked(preservePending: false)
            self.session = session
            self.restartLocked(preservePending: false)
        }
    }

    /// Открывает канал с выбранной конфигурацией. Completion относится именно к этому запуску.
    func apply(_ newConfig: WireConfig, persist: Bool = true, completion: ((Bool) -> Void)? = nil) {
        if persist { newConfig.save() }
        DispatchQueue.main.async { self.config = newConfig }
        queue.async {
            self.finishOpen(false)
            self.openCompletion = completion
            self.isProbing = (completion != nil)
            self.reconnectAttempt = 0
            self.cfg = newConfig
            if self.session != nil {
                self.restartLocked(preservePending: false)
            } else {
                self.isProbing = false
                self.finishOpen(false)
            }
        }
    }

    func commitCurrent() {
        queue.async { self.cfg.save() }
    }

    private func finishOpen(_ success: Bool) {
        guard let completion = openCompletion else { return }
        openCompletion = nil
        DispatchQueue.main.async { completion(success) }
    }

    func keyDown(_ code: Int32) {
        guard code >= 0 else { return }
        let uCode = UInt32(code)
        queue.async {
            self.pending.append(PendingEvent(payload: .button(code: uCode, pressed: true), delayAfter: 0.025))
            self.wakeIfDisconnectedLocked()
            self.flushIfReady()
        }
    }

    func keyUp(_ code: Int32) {
        guard code >= 0 else { return }
        let uCode = UInt32(code)
        queue.async {
            self.pending.append(PendingEvent(payload: .button(code: uCode, pressed: false), delayAfter: 0.015))
            self.wakeIfDisconnectedLocked()
            self.flushIfReady()
        }
    }

    func press(_ code: Int32) {
        guard code >= 0 else { return }
        let uCode = UInt32(code)
        queue.async {
            self.pending.append(PendingEvent(payload: .button(code: uCode, pressed: true), delayAfter: 0.035))
            self.pending.append(PendingEvent(payload: .button(code: uCode, pressed: false), delayAfter: 0.015))
            self.wakeIfDisconnectedLocked()
            self.flushIfReady()
        }
    }

    func longPress(_ code: Int32, duration: TimeInterval = 1.1) {
        guard code >= 0 else { return }
        let uCode = UInt32(code)
        queue.async {
            self.pending.append(PendingEvent(payload: .button(code: uCode, pressed: true), delayAfter: max(0.6, duration)))
            self.pending.append(PendingEvent(payload: .button(code: uCode, pressed: false), delayAfter: 0.02))
            self.wakeIfDisconnectedLocked()
            self.flushIfReady()
        }
    }

    /// Отправляет клавишу клавиатуры (`KeyboardSignal`, Linux input-event code: Backspace=14, Enter=28).
    func sendKeyboardKey(_ keyCode: Int32) {
        queue.async {
            self.pending.append(PendingEvent(payload: .keyboardSignal(keyCode: keyCode, pressed: true), delayAfter: 0.03))
            self.pending.append(PendingEvent(payload: .keyboardSignal(keyCode: keyCode, pressed: false), delayAfter: 0.02))
            self.wakeIfDisconnectedLocked()
            self.flushIfReady()
        }
    }

    /// Отправляет произвольную UTF-8 строку (русский, английский, цифры, символы) через `KeyboardSymbols`.
    func typeSymbols(_ text: String) {
        guard !text.isEmpty else { return }
        queue.async {
            self.pending.append(PendingEvent(payload: .keyboardSymbols(text: text), delayAfter: 0.04))
            self.wakeIfDisconnectedLocked()
            self.flushIfReady()
        }
    }

    func launchApp(packageName: String, signal: UInt32 = 1) {
        guard !packageName.isEmpty else { return }
        queue.async {
            self.pending.append(PendingEvent(payload: .launchApp(signal: signal, packageName: packageName), delayAfter: 0.04))
            self.wakeIfDisconnectedLocked()
            self.flushIfReady()
        }
    }

    /// Останавливает периодический Ping при уходе приложения в фон, сохраняя параметры сессии.
    func pauseKeepalive() {
        queue.async {
            self.stopPingTimerLocked()
            self.introRetryWorkItem?.cancel()
            self.introRetryWorkItem = nil
        }
    }

    /// Возобновляет Ping (и повторно отправляет Introduction при необходимости) после возврата из фона.
    func resumeKeepalive() {
        queue.async {
            guard self.session != nil else { return }
            if self.transportReady, self.connection != nil {
                if let sid = self.session?.sessionId {
                    self.sendIntroductionLocked(sessionId: sid, generation: self.generation)
                }
                self.startPingTimerLocked(generation: self.generation)
            } else {
                self.wakeIfDisconnectedLocked()
            }
        }
    }

    func stop() {
        queue.async {
            self.session = nil
            self.isProbing = false
            self.reconnectAttempt = 0
            self.teardownLocked(preservePending: false)
            self.finishOpen(false)
        }
    }

    private func wakeIfDisconnectedLocked() {
        guard !transportReady,
              connection == nil,
              reconnectWorkItem == nil,
              !isProbing,
              session != nil else { return }
        reconnectAttempt = 0
        restartLocked(preservePending: true)
    }

    private func stopPingTimerLocked() {
        pingTimer?.setEventHandler {}
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func teardownLocked(preservePending: Bool) {
        generation += 1
        stopPingTimerLocked()
        introRetryWorkItem?.cancel()
        introRetryWorkItem = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        delayWorkItem?.cancel()
        delayWorkItem = nil
        connection?.cancel()
        connection = nil
        transportReady = false
        introAcked = false
        setReady(false)
        setHandshakeConfirmed(false)
        sendInFlight = false
        if !preservePending {
            pending.removeAll()
        }
        hosts.removeAll()
        hostIndex = 0
    }

    private func restartLocked(preservePending: Bool) {
        teardownLocked(preservePending: preservePending)
        guard let session else {
            finishOpen(false)
            return
        }
        key = Self.deriveKey(session.aesKey, cfg.keyMode)
        guard let resolvedKey = key else {
            DebugLog.add("⚠️ Ключ не подходит под режим \(cfg.keyMode.rawValue) (\(Self.describeKey(session.aesKey)))")
            finishOpen(false)
            return
        }

        if cfg.cipher == .ecb || cfg.ivMode == .prefixedRandom {
            staticIV = nil
        } else {
            let ivLen = cfg.cipher == .gcm ? 12 : 16
            staticIV = Self.deriveIV(session.sessionId, cfg.ivMode, length: ivLen)
            guard staticIV != nil else {
                DebugLog.add("⚠️ IV не подходит под режим \(cfg.ivMode.rawValue)")
                finishOpen(false)
                return
            }
        }

        let ivDesc = cfg.cipher == .ecb ? "none" : (cfg.ivMode == .prefixedRandom ? "rand" : "\(staticIV?.count ?? 0)Б")
        DebugLog.add("🔑 Ключ \(resolvedKey.count) Б (\(cfg.cipher.title)), IV:\(ivDesc) [\(Self.describeKey(session.aesKey))]")
        hosts = Array(session.ipv4)
        hostIndex = 0
        order = 0
        lastServerOrder = -1
        sentLogged = 0
        openNext()
    }

    private func setReady(_ value: Bool) {
        transportReady = value
        DispatchQueue.main.async {
            if self.ready != value { self.ready = value }
        }
    }

    private func setHandshakeConfirmed(_ value: Bool) {
        DispatchQueue.main.async {
            if self.handshakeConfirmed != value { self.handshakeConfirmed = value }
        }
    }

    private func openNext() {
        guard let session,
              session.port > 0,
              session.port <= UInt(UInt16.max),
              let port = NWEndpoint.Port(rawValue: UInt16(session.port)),
              hostIndex < hosts.count else {
            setReady(false)
            DebugLog.add("✖︎ Не удалось открыть канал (\(cfg.transport.rawValue.uppercased())) ни по одному адресу")
            if isProbing {
                isProbing = false
                finishOpen(false)
            } else {
                finishOpen(false)
                scheduleReconnectOrNotifyLocked(reason: "все адреса недоступны")
            }
            return
        }

        let host = hosts[hostIndex]
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: cfg.transport == .udp ? .udp : .tcp
        )
        connection = conn
        generation += 1
        let currentGeneration = generation
        var isReady = false
        DebugLog.add("→ \(cfg.transport.rawValue.uppercased()) \(host):\(session.port)")

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self else { return }
            self.queue.async {
                guard currentGeneration == self.generation, self.connection === conn else { return }
                switch state {
                case .ready:
                    isReady = true
                    self.reconnectAttempt = 0
                    self.isProbing = false
                    DebugLog.add("✓ канал открыт \(host)")
                    self.setReady(true)
                    if let conn { self.receiveLoop(conn, generation: currentGeneration) }
                    // Обязательное рукопожатие официального протокола: Introduction (field 21) + Ping (field 15) раз в 500 мс.
                    self.sendIntroductionLocked(sessionId: session.sessionId, generation: currentGeneration)
                    self.startPingTimerLocked(generation: currentGeneration)
                    self.finishOpen(true)
                    self.flushIfReady()
                case .failed(let error):
                    DebugLog.add("✖︎ \(host): \(error.localizedDescription)")
                    self.advance()
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)

        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, currentGeneration == self.generation, !isReady else { return }
            DebugLog.add("⏱ таймаут \(host)")
            self.advance()
        }
    }

    private func advance() {
        stopPingTimerLocked()
        introRetryWorkItem?.cancel()
        introRetryWorkItem = nil
        connection?.cancel()
        connection = nil
        setReady(false)
        setHandshakeConfirmed(false)
        sendInFlight = false
        hostIndex += 1
        openNext()
    }

    private func handleDisconnectLocked(requeue item: PendingEvent? = nil, reason: String) {
        generation += 1
        stopPingTimerLocked()
        introRetryWorkItem?.cancel()
        introRetryWorkItem = nil
        delayWorkItem?.cancel()
        delayWorkItem = nil
        connection?.cancel()
        connection = nil
        setReady(false)
        setHandshakeConfirmed(false)
        sendInFlight = false

        if let item {
            pending.insert(item, at: 0)
            if pending.count > 40 {
                pending.removeLast(pending.count - 40)
            }
        }

        guard !isProbing, session != nil else {
            finishOpen(false)
            return
        }

        if hostIndex + 1 < hosts.count {
            hostIndex += 1
            openNext()
        } else {
            scheduleReconnectOrNotifyLocked(reason: reason)
        }
    }

    private func scheduleReconnectOrNotifyLocked(reason: String) {
        guard !isProbing, session != nil else { return }

        if reconnectAttempt < maxReconnectAttempts {
            reconnectAttempt += 1
            let attempt = reconnectAttempt
            let delay = Double(attempt) * 0.8
            DebugLog.add("↻ переподключение канала пульта (\(attempt)/\(maxReconnectAttempts)) через \(String(format: "%.1f", delay)) с: \(reason)")

            reconnectWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      !self.isProbing,
                      self.session != nil,
                      !self.transportReady,
                      self.connection == nil else { return }
                self.reconnectWorkItem = nil
                self.restartLocked(preservePending: true)
            }
            reconnectWorkItem = work
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            DebugLog.add("✖︎ локальные попытки переподключения исчерпаны (\(reason)) — запрашиваем новую сессию")
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            pending.removeAll()
            let callback = onReconnectNeeded
            DispatchQueue.main.async { callback?() }
        }
    }

    // MARK: - Handshake (Introduction) & Keepalive (Ping 500ms)

    private func sendIntroductionLocked(sessionId: String, generation expectedGen: Int) {
        guard transportReady, expectedGen == generation else { return }
        let msg = Self.encodeIntroduction(
            sessionId: sessionId,
            gamepadName: Self.clientName,
            apiVersion: Self.gamepadApiVersion
        )
        sendImmediateDatagramLocked(protobuf: msg, label: "Introduction(v\(Self.gamepadApiVersion))", logAlways: true)

        // Если UDP-пакет Introduction потерялся и ТВ не ответил за 400 мс — повторяем один раз.
        introRetryWorkItem?.cancel()
        let retry = DispatchWorkItem { [weak self] in
            guard let self,
                  expectedGen == self.generation,
                  self.transportReady,
                  !self.introAcked,
                  let sid = self.session?.sessionId else { return }
            let retryMsg = Self.encodeIntroduction(
                sessionId: sid,
                gamepadName: Self.clientName,
                apiVersion: Self.gamepadApiVersion
            )
            self.sendImmediateDatagramLocked(protobuf: retryMsg, label: "Introduction(повтор)", logAlways: true)
        }
        introRetryWorkItem = retry
        queue.asyncAfter(deadline: .now() + 0.4, execute: retry)
    }

    private func startPingTimerLocked(generation expectedGen: Int) {
        stopPingTimerLocked()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self,
                  expectedGen == self.generation,
                  self.transportReady,
                  self.connection != nil else { return }
            let nowMs = UInt64(Date().timeIntervalSince1970 * 1000.0)
            let ping = Self.encodePing(timeMs: nowMs)
            self.sendImmediateDatagramLocked(protobuf: ping, label: "Ping", logAlways: false)
        }
        pingTimer = timer
        timer.resume()
    }

    private func buildPacketLocked(protobuf: Data) -> Data? {
        guard let key else { return nil }
        order &+= 1
        let orderBytes = Data(Self.be32(order))

        let plaintext: Data
        switch cfg.framing {
        case .rawEnc, .orderEnc, .lenOrderEnc:
            plaintext = protobuf
        case .encOrder, .lenEncOrder:
            plaintext = orderBytes + protobuf
        }

        guard let encrypted = Self.encrypt(plaintext, key: key, cipher: cfg.cipher, ivMode: cfg.ivMode, staticIV: staticIV) else {
            return nil
        }

        let payload: Data
        switch cfg.framing {
        case .rawEnc, .encOrder, .lenEncOrder:
            payload = encrypted
        case .orderEnc, .lenOrderEnc:
            payload = orderBytes + encrypted
        }

        var packet = Data()
        if cfg.framing.hasLength {
            packet.append(contentsOf: Self.be32(UInt32(payload.count)))
        }
        packet.append(payload)
        return packet
    }

    private func sendImmediateDatagramLocked(protobuf: Data, label: String, logAlways: Bool) {
        guard transportReady, let connection else { return }
        guard let packet = buildPacketLocked(protobuf: protobuf) else {
            DebugLog.add("✖︎ ошибка шифрования \(label) (\(cfg.cipher.title))")
            return
        }
        let currentGeneration = generation
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard currentGeneration == self.generation else { return }
                if let error {
                    DebugLog.add("✖︎ \(label): \(error.localizedDescription)")
                } else if logAlways {
                    DebugLog.add("↑ \(label) (\(packet.count) Б, order=\(self.order))")
                }
            }
        })
    }

    // MARK: - Receive & Decrypt TV Responses (`Message.Device`)

    private func receiveLoop(_ conn: NWConnection, generation: Int) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.queue.async {
                guard generation == self.generation, self.connection === conn else { return }
                if let data, !data.isEmpty {
                    self.handleIncomingDatagramLocked(data)
                }
                if let error {
                    DebugLog.add("← ошибка приёма: \(error.localizedDescription)")
                    self.handleDisconnectLocked(reason: "ошибка приёма")
                    return
                }
                if complete && self.cfg.transport == .tcp {
                    DebugLog.add("← ТВ закрыл TCP-соединение")
                    self.handleDisconnectLocked(reason: "ТВ закрыл TCP")
                    return
                }
                self.receiveLoop(conn, generation: generation)
            }
        }
    }

    private func handleIncomingDatagramLocked(_ data: Data) {
        if let key, let iv = staticIV, cfg.cipher == .cbc,
           let plain = Self.aesCBCDecrypt(data, key: key, iv: iv),
           plain.count >= 4 {
            let tvOrder = Int32(bitPattern:
                (UInt32(plain[0]) << 24) |
                (UInt32(plain[1]) << 16) |
                (UInt32(plain[2]) << 8) |
                UInt32(plain[3])
            )
            if tvOrder > lastServerOrder {
                lastServerOrder = tvOrder
            }
            let body = plain.subdata(in: 4..<plain.count)
            let fieldNum = Self.firstProtobufFieldNumber(body)
            // Поле 16 в Message.Device = Connection (подтверждение Introduction), поле 15 = Pong.
            if fieldNum == 16 || !introAcked {
                introAcked = true
                introRetryWorkItem?.cancel()
                introRetryWorkItem = nil
                setHandshakeConfirmed(true)
                DebugLog.add("✓ ТВ подтвердил канал пульта (field=\(fieldNum ?? 0), order=\(tvOrder), \(body.count) Б)")
            }
        } else {
            let hex = data.prefix(16).map { String(format: "%02x", $0) }.joined()
            DebugLog.add("← ТВ ответил \(data.count) Б: \(hex)")
        }
    }

    private static func firstProtobufFieldNumber(_ data: Data) -> UInt64? {
        guard !data.isEmpty else { return nil }
        var tag: UInt64 = 0
        var shift: UInt64 = 0
        for byte in data {
            tag |= UInt64(byte & 0x7f) << shift
            if (byte & 0x80) == 0 {
                return tag >> 3
            }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    // MARK: - Outbound Command Queue

    private func flushIfReady() {
        guard transportReady, !sendInFlight, !pending.isEmpty,
              let connection else { return }

        let item = pending.removeFirst()
        let message = Self.encodePayload(item.payload, mode: cfg.payloadMode)

        guard let packet = buildPacketLocked(protobuf: message) else {
            DebugLog.add("✖︎ ошибка шифрования (\(cfg.cipher.title))")
            pending.removeAll()
            return
        }

        sendInFlight = true
        let currentGeneration = generation
        let label = item.payload.logLabel
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard currentGeneration == self.generation else { return }
                if let error {
                    self.sendInFlight = false
                    DebugLog.add("✖︎ отправка: \(error.localizedDescription)")
                    self.handleDisconnectLocked(requeue: item, reason: "ошибка отправки")
                } else {
                    if self.sentLogged < 8 {
                        self.sentLogged += 1
                        DebugLog.add("↑ отправлено \(packet.count) Б (\(label))")
                    }
                    if item.delayAfter > 0 {
                        self.delayWorkItem?.cancel()
                        let work = DispatchWorkItem { [weak self] in
                            guard let self, currentGeneration == self.generation else { return }
                            self.delayWorkItem = nil
                            self.sendInFlight = false
                            self.flushIfReady()
                        }
                        self.delayWorkItem = work
                        self.queue.asyncAfter(deadline: .now() + item.delayAfter, execute: work)
                    } else {
                        self.sendInFlight = false
                        self.flushIfReady()
                    }
                }
            }
        })
    }

    // MARK: - Protobuf3 Encoders (`ru.sberdevices.gamepad.proto.Message.Gamepad`)

    private static func encodePayload(_ payload: OutboundPayload, mode: WireConfig.PayloadMode) -> Data {
        switch payload {
        case .introduction(let sessionId):
            return encodeIntroduction(sessionId: sessionId, gamepadName: clientName, apiVersion: gamepadApiVersion)
        case .button(let code, let pressed):
            return encodeButton(code: code, pressed: pressed, mode: mode)
        case .keyboardSignal(let keyCode, let pressed):
            return encodeKeyboardSignal(keyCode: keyCode, pressed: pressed)
        case .keyboardSymbols(let text):
            return encodeKeyboardSymbols(text: text)
        case .launchApp(let signal, let packageName):
            return encodeLaunchApp(signal: signal, packageName: packageName)
        }
    }

    /// `Message.Gamepad { button = 1 (code = 1 uint32, pressed = 2 bool) }` (proto3).
    private static func encodeButton(code: UInt32, pressed: Bool, mode: WireConfig.PayloadMode) -> Data {
        switch mode {
        case .protoBool:
            var inner = Data()
            if code != 0 {
                inner.append(0x08)
                inner.append(contentsOf: varint(UInt64(code)))
            }
            if pressed {
                inner.append(contentsOf: [0x10, 0x01])
            }
            return lengthDelimitedField(1, inner)
        case .protoAction:
            return lengthDelimitedField(1, legacyButton(code: code, stateByte: pressed ? 0x00 : 0x01))
        case .protoFlat:
            return legacyButton(code: code, stateByte: pressed ? 0x01 : 0x00)
        case .protoFlatAction:
            return legacyButton(code: code, stateByte: pressed ? 0x00 : 0x01)
        }
    }

    private static func legacyButton(code: UInt32, stateByte: UInt8) -> Data {
        var data = Data([0x08])
        data.append(contentsOf: varint(UInt64(code)))
        data.append(contentsOf: [0x10, stateByte])
        return data
    }

    /// `Message.Gamepad { introduction = 21 { sessionId = 1, gamepadName = 2, apiVersion = 3 } }`.
    private static func encodeIntroduction(sessionId: String, gamepadName: String, apiVersion: String) -> Data {
        var inner = Data()
        if !sessionId.isEmpty { inner.append(stringField(1, sessionId)) }
        if !gamepadName.isEmpty { inner.append(stringField(2, gamepadName)) }
        if !apiVersion.isEmpty { inner.append(stringField(3, apiVersion)) }
        return lengthDelimitedField(21, inner)
    }

    /// `Message.Gamepad { ping = 15 { time = 1 uint64 } }`.
    private static func encodePing(timeMs: UInt64) -> Data {
        var inner = Data()
        if timeMs != 0 {
            inner.append(0x08)
            inner.append(contentsOf: varint(timeMs))
        }
        return lengthDelimitedField(15, inner)
    }

    /// `Message.Gamepad { keyboardSignal = 5 { keyCode = 1 int32, pressed = 2 bool } }`.
    private static func encodeKeyboardSignal(keyCode: Int32, pressed: Bool) -> Data {
        var inner = Data()
        if keyCode != 0 {
            inner.append(0x08)
            inner.append(contentsOf: varint(UInt64(bitPattern: Int64(keyCode))))
        }
        if pressed {
            inner.append(contentsOf: [0x10, 0x01])
        }
        return lengthDelimitedField(5, inner)
    }

    /// `Message.Gamepad { keyboardSymbols = 8 { text = 1 string } }`.
    private static func encodeKeyboardSymbols(text: String) -> Data {
        var inner = Data()
        if !text.isEmpty {
            inner.append(stringField(1, text))
        }
        return lengthDelimitedField(8, inner)
    }

    /// `Message.Gamepad { launchApp = 17 { signal = 1 uint32, packageName = 2 string } }`.
    private static func encodeLaunchApp(signal: UInt32, packageName: String) -> Data {
        var inner = Data()
        if signal != 0 {
            inner.append(0x08)
            inner.append(contentsOf: varint(UInt64(signal)))
        }
        if !packageName.isEmpty {
            inner.append(stringField(2, packageName))
        }
        return lengthDelimitedField(17, inner)
    }

    private static func stringField(_ number: UInt64, _ value: String) -> Data {
        lengthDelimitedField(number, Data(value.utf8))
    }

    private static func lengthDelimitedField(_ number: UInt64, _ bytes: Data) -> Data {
        var data = Data(varint((number << 3) | 2))
        data.append(contentsOf: varint(UInt64(bytes.count)))
        data.append(bytes)
        return data
    }

    private static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var output: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            output.append(byte)
        } while value != 0
        return output
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    // MARK: - Key / IV / Crypto

    static func deriveIV(_ sessionId: String, _ mode: WireConfig.IVMode, length: Int = 16) -> Data? {
        switch mode {
        case .prefixedRandom:
            return randomBytes(count: length)
        case .uuidBytes:
            guard let uuid = UUID(uuidString: sessionId) else { return nil }
            var raw = uuid.uuid
            let full = withUnsafeBytes(of: &raw) { Data($0) }
            return full.count >= length ? full.prefix(length) : nil
        case .utf8Lower:
            let data = Data(sessionId.lowercased().utf8)
            return data.count >= length ? data.prefix(length) : nil
        case .zero:
            return Data(repeating: 0, count: length)
        }
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    static func decodeBase64Flexible(_ string: String) -> Data? {
        var cleaned = string
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !cleaned.isEmpty else { return nil }
        let rem = cleaned.count % 4
        if rem != 0 {
            cleaned.append(String(repeating: "=", count: 4 - rem))
        }
        return Data(base64Encoded: cleaned)
    }

    static func decodeHexFlexible(_ string: String) -> Data? {
        var cleaned = string
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        if cleaned.hasPrefix("0x") || cleaned.hasPrefix("0X") {
            cleaned.removeFirst(2)
        }
        cleaned = cleaned
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    static func deriveKey(_ string: String, _ mode: WireConfig.KeyMode) -> Data? {
        let validLengths = [16, 24, 32]
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch mode {
        case .auto:
            return deriveKey(string, .base64) ?? deriveKey(string, .hex) ?? deriveKey(string, .utf8)
        case .hex:
            guard let data = decodeHexFlexible(trimmed), validLengths.contains(data.count) else { return nil }
            return data
        case .base64:
            guard let data = decodeBase64Flexible(trimmed) else { return nil }
            if validLengths.contains(data.count) { return data }
            if let inner = String(data: data, encoding: .utf8),
               let hexData = decodeHexFlexible(inner),
               validLengths.contains(hexData.count) {
                return hexData
            }
            return nil
        case .utf8:
            let data = Data(trimmed.utf8)
            return validLengths.contains(data.count) ? data : nil
        }
    }

    static func describeKey(_ string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasWS = string.count != trimmed.count || trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        let b64Bytes = decodeBase64Flexible(trimmed)?.count
        let hexBytes = decodeHexFlexible(trimmed)?.count
        let specials = [":", ",", "{", "[", "-", "_"].filter { trimmed.contains($0) }.joined()
        return "len:\(string.count)/trim:\(trimmed.count), ws:\(hasWS ? "да" : "нет"), b64:\(b64Bytes.map(String.init) ?? "—")Б, hex:\(hexBytes.map(String.init) ?? "—")Б, sym:\(specials.isEmpty ? "—" : specials)"
    }

    private static func encrypt(
        _ data: Data,
        key: Data,
        cipher: WireConfig.CipherMode,
        ivMode: WireConfig.IVMode,
        staticIV: Data?
    ) -> Data? {
        switch cipher {
        case .gcm:
            let symKey = SymmetricKey(data: key)
            if ivMode == .prefixedRandom {
                let nonce = AES.GCM.Nonce()
                guard let sealed = try? AES.GCM.seal(data, using: symKey, nonce: nonce) else { return nil }
                return sealed.combined
            } else {
                guard let iv = staticIV, let nonce = try? AES.GCM.Nonce(data: iv),
                      let sealed = try? AES.GCM.seal(data, using: symKey, nonce: nonce) else { return nil }
                return sealed.ciphertext + sealed.tag
            }

        case .cbc:
            if ivMode == .prefixedRandom {
                let iv = randomBytes(count: kCCBlockSizeAES128)
                guard let enc = aesCBCCrypt(data, key: key, iv: iv, operation: CCOperation(kCCEncrypt)) else { return nil }
                return iv + enc
            } else {
                guard let iv = staticIV else { return nil }
                return aesCBCCrypt(data, key: key, iv: iv, operation: CCOperation(kCCEncrypt))
            }

        case .ecb:
            return aesECBEncrypt(data, key: key)
        }
    }

    private static func aesCBCDecrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        aesCBCCrypt(data, key: key, iv: iv, operation: CCOperation(kCCDecrypt))
    }

    private static func aesCBCCrypt(_ data: Data, key: Data, iv: Data, operation: CCOperation) -> Data? {
        guard iv.count == kCCBlockSizeAES128 else { return nil }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            outputBytes.baseAddress, capacity, &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(moved..<output.count)
        return output
    }

    private static func aesECBEncrypt(_ data: Data, key: Data) -> Data? {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                        keyBytes.baseAddress, key.count,
                        nil,
                        dataBytes.baseAddress, data.count,
                        outputBytes.baseAddress, capacity, &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(moved..<output.count)
        return output
    }
}
