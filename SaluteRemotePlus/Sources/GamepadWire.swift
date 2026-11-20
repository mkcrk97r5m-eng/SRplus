import Foundation
import Network
import Security
import CommonCrypto
import CryptoKit

/// Вариант формата канала «gamepad» (порт 6801 на Salute TV использует UDP + AES-256).
struct WireConfig: Codable, Equatable {
    enum Transport: String, Codable, CaseIterable { case udp, tcp }

    enum CipherMode: String, Codable, CaseIterable {
        case gcm
        case cbc
        case ecb

        var title: String {
            switch self {
            case .gcm: return "AES-GCM"
            case .cbc: return "AES-CBC"
            case .ecb: return "AES-ECB"
            }
        }
    }

    enum Framing: String, Codable, CaseIterable {
        case rawEnc
        case orderEnc
        case encOrder
        case lenOrderEnc
        case lenEncOrder

        var hasLength: Bool { self == .lenOrderEnc || self == .lenEncOrder }
        var title: String {
            switch self {
            case .rawEnc: return "AES(msg)"
            case .orderEnc: return "order|AES(msg)"
            case .encOrder: return "AES(order+msg)"
            case .lenOrderEnc: return "len|order|AES"
            case .lenEncOrder: return "len|AES(order+msg)"
            }
        }
    }

    enum KeyMode: String, Codable, CaseIterable { case auto, base64, hex, utf8 }

    enum IVMode: String, Codable, CaseIterable {
        case prefixedRandom
        case uuidBytes
        case utf8Lower
        case zero

        var title: String {
            switch self {
            case .prefixedRandom: return "iv+enc"
            case .uuidBytes: return "uuid"
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
            case .protoBool: return "pb:1/0"
            case .protoAction: return "pb:0/1"
            case .protoFlat: return "flat:1/0"
            case .protoFlatAction: return "flat:0/1"
            }
        }
    }

    var transport: Transport = .udp
    var cipher: CipherMode = .gcm
    var framing: Framing = .rawEnc
    var keyMode: KeyMode = .auto
    var ivMode: IVMode = .prefixedRandom
    var payloadMode: PayloadMode = .protoBool

    init(
        transport: Transport = .udp,
        cipher: CipherMode = .gcm,
        framing: Framing = .rawEnc,
        keyMode: KeyMode = .auto,
        ivMode: IVMode = .prefixedRandom,
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
        cipher = try c.decodeIfPresent(CipherMode.self, forKey: .cipher) ?? .gcm
        framing = try c.decodeIfPresent(Framing.self, forKey: .framing) ?? .rawEnc
        keyMode = try c.decodeIfPresent(KeyMode.self, forKey: .keyMode) ?? .auto
        ivMode = try c.decodeIfPresent(IVMode.self, forKey: .ivMode) ?? .prefixedRandom
        payloadMode = try c.decodeIfPresent(PayloadMode.self, forKey: .payloadMode) ?? .protoBool
    }

    static let baseline = WireConfig()
    private static let storeKey = "SaluteRemotePlus.wireConfig.v2"

    var title: String {
        let ivLabel = cipher == .ecb ? "none" : ivMode.title
        return "\(transport.rawValue.uppercased()) · \(cipher.title) · \(framing.title) · iv:\(ivLabel) · \(payloadMode.title)"
    }

    /// Компактный список UDP-кандидатов для автоподбора (TCP 6801 не слушает).
    static func candidates(for session: GamepadSession) -> [WireConfig] {
        guard GamepadWire.deriveKey(session.aesKey, .auto) != nil else { return [] }

        let udpFramings: [Framing] = [.rawEnc, .orderEnc, .encOrder]
        var result: [WireConfig] = []

        // 1. Стандартный protobuf (pressed = 1/0): AES-GCM, AES-CBC, AES-ECB
        for framing in udpFramings {
            for ivMode in [IVMode.prefixedRandom, .uuidBytes, .utf8Lower, .zero] {
                if ivMode == .prefixedRandom || GamepadWire.deriveIV(session.sessionId, ivMode, length: 12) != nil {
                    result.append(WireConfig(transport: .udp, cipher: .gcm, framing: framing, keyMode: .auto, ivMode: ivMode, payloadMode: .protoBool))
                }
            }
        }
        for framing in udpFramings {
            for ivMode in [IVMode.prefixedRandom, .zero, .uuidBytes, .utf8Lower] {
                if ivMode == .prefixedRandom || GamepadWire.deriveIV(session.sessionId, ivMode, length: 16) != nil {
                    result.append(WireConfig(transport: .udp, cipher: .cbc, framing: framing, keyMode: .auto, ivMode: ivMode, payloadMode: .protoBool))
                }
            }
        }
        for framing in udpFramings {
            result.append(WireConfig(transport: .udp, cipher: .ecb, framing: framing, keyMode: .auto, ivMode: .zero, payloadMode: .protoBool))
        }

        // 2. Android KeyEvent action (ACTION_DOWN=0, ACTION_UP=1) и плоский protobuf
        for payloadMode in [PayloadMode.protoAction, .protoFlat, .protoFlatAction] {
            for framing in [Framing.rawEnc, .orderEnc, .encOrder] {
                for ivMode in [IVMode.prefixedRandom, .uuidBytes, .zero] {
                    if ivMode == .prefixedRandom || GamepadWire.deriveIV(session.sessionId, ivMode, length: 12) != nil {
                        result.append(WireConfig(transport: .udp, cipher: .gcm, framing: framing, keyMode: .auto, ivMode: ivMode, payloadMode: payloadMode))
                    }
                    if ivMode == .prefixedRandom || GamepadWire.deriveIV(session.sessionId, ivMode, length: 16) != nil {
                        result.append(WireConfig(transport: .udp, cipher: .cbc, framing: framing, keyMode: .auto, ivMode: ivMode, payloadMode: payloadMode))
                    }
                }
            }
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
    @Published private(set) var config = WireConfig.load()

    private let queue = DispatchQueue(label: "SaluteRemotePlus.GamepadWire")
    private var connection: NWConnection?
    private var session: GamepadSession?
    private var cfg = WireConfig.load()
    private var key: Data?
    private var staticIV: Data?
    private struct PendingEvent {
        let code: Int32
        let pressed: Bool
        let delayAfter: TimeInterval
    }

    private var hosts: [String] = []
    private var hostIndex = 0
    private var pending: [PendingEvent] = []
    private var sendInFlight = false
    private var delayWorkItem: DispatchWorkItem?
    private var order: UInt32 = 0
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
        queue.async {
            self.pending.append(PendingEvent(code: code, pressed: true, delayAfter: 0.035))
            self.wakeIfDisconnectedLocked()
            self.flushIfReady()
        }
    }

    func keyUp(_ code: Int32) {
        queue.async {
            self.pending.append(PendingEvent(code: code, pressed: false, delayAfter: 0.015))
            self.wakeIfDisconnectedLocked()
            self.flushIfReady()
        }
    }

    func press(_ code: Int32) {
        queue.async {
            self.pending.append(PendingEvent(code: code, pressed: true, delayAfter: 0.04))
            self.pending.append(PendingEvent(code: code, pressed: false, delayAfter: 0.02))
            self.wakeIfDisconnectedLocked()
            self.flushIfReady()
        }
    }

    func longPress(_ code: Int32, duration: TimeInterval = 1.1) {
        queue.async {
            self.pending.append(PendingEvent(code: code, pressed: true, delayAfter: max(0.6, duration)))
            self.pending.append(PendingEvent(code: code, pressed: false, delayAfter: 0.02))
            self.wakeIfDisconnectedLocked()
            self.flushIfReady()
        }
    }

    @discardableResult
    func type(_ text: String) -> [Character] {
        var skipped: [Character] = []
        var codes: [Int32] = []
        for character in text {
            if let code = KeyMap.code(for: character) { codes.append(code) }
            else { skipped.append(character) }
        }
        queue.async {
            for code in codes {
                self.pending.append(PendingEvent(code: code, pressed: true, delayAfter: 0.025))
                self.pending.append(PendingEvent(code: code, pressed: false, delayAfter: 0.025))
            }
            self.wakeIfDisconnectedLocked()
            self.flushIfReady()
        }
        return skipped
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

    private func teardownLocked(preservePending: Bool) {
        generation += 1
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        delayWorkItem?.cancel()
        delayWorkItem = nil
        connection?.cancel()
        connection = nil
        transportReady = false
        setReady(false)
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
        sentLogged = 0
        openNext()
    }

    private func setReady(_ value: Bool) {
        transportReady = value
        DispatchQueue.main.async {
            if self.ready != value { self.ready = value }
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
                    self.finishOpen(true)
                    if let conn { self.receiveLoop(conn, generation: currentGeneration) }
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
        connection?.cancel()
        connection = nil
        setReady(false)
        sendInFlight = false
        hostIndex += 1
        openNext()
    }

    private func handleDisconnectLocked(requeue item: PendingEvent? = nil, reason: String) {
        generation += 1
        delayWorkItem?.cancel()
        delayWorkItem = nil
        connection?.cancel()
        connection = nil
        setReady(false)
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

    private func receiveLoop(_ conn: NWConnection, generation: Int) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.queue.async {
                guard generation == self.generation, self.connection === conn else { return }
                if let data, !data.isEmpty {
                    let hex = data.prefix(24).map { String(format: "%02x", $0) }.joined()
                    DebugLog.add("← ТВ ответил \(data.count) Б: \(hex)")
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

    private func flushIfReady() {
        guard transportReady, !sendInFlight, !pending.isEmpty,
              let connection, let key else { return }

        let item = pending.removeFirst()
        let code = item.code
        let pressed = item.pressed
        let message = Self.encodeButton(code: code, pressed: pressed, mode: cfg.payloadMode)

        order &+= 1
        let orderBytes = Data(Self.be32(order))

        let plaintext: Data
        switch cfg.framing {
        case .rawEnc, .orderEnc, .lenOrderEnc:
            plaintext = message
        case .encOrder, .lenEncOrder:
            plaintext = orderBytes + message
        }

        guard let encrypted = Self.encrypt(plaintext, key: key, cipher: cfg.cipher, ivMode: cfg.ivMode, staticIV: staticIV) else {
            DebugLog.add("✖︎ ошибка шифрования (\(cfg.cipher.title))")
            pending.removeAll()
            return
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

        sendInFlight = true
        let currentGeneration = generation
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard currentGeneration == self.generation else { return }
                if let error {
                    self.sendInFlight = false
                    DebugLog.add("✖︎ отправка: \(error.localizedDescription)")
                    self.handleDisconnectLocked(requeue: item, reason: "ошибка отправки")
                } else {
                    if self.sentLogged < 4 {
                        self.sentLogged += 1
                        DebugLog.add("↑ отправлено \(packet.count) Б (код \(code) \(pressed ? "↓" : "↑"))")
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

    // MARK: - Protobuf helpers

    private static func encodeButton(code: Int32, pressed: Bool, mode: WireConfig.PayloadMode) -> Data {
        switch mode {
        case .protoBool:
            return field(1, buttonMessage(code: code, stateByte: pressed ? 0x01 : 0x00))
        case .protoAction:
            return field(1, buttonMessage(code: code, stateByte: pressed ? 0x00 : 0x01))
        case .protoFlat:
            return buttonMessage(code: code, stateByte: pressed ? 0x01 : 0x00)
        case .protoFlatAction:
            return buttonMessage(code: code, stateByte: pressed ? 0x00 : 0x01)
        }
    }

    private static func buttonMessage(code: Int32, stateByte: UInt8) -> Data {
        var data = Data([0x08])
        data.append(contentsOf: varint(UInt64(UInt32(bitPattern: code))))
        data.append(contentsOf: [0x10, stateByte])
        return data
    }

    private static func field(_ number: UInt64, _ bytes: Data) -> Data {
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
                guard let enc = aesCBCEncrypt(data, key: key, iv: iv) else { return nil }
                return iv + enc
            } else {
                guard let iv = staticIV else { return nil }
                return aesCBCEncrypt(data, key: key, iv: iv)
            }

        case .ecb:
            return aesECBEncrypt(data, key: key)
        }
    }

    private static func aesCBCEncrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard iv.count == kCCBlockSizeAES128 else { return nil }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
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
