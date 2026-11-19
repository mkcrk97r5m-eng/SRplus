import Foundation
import Network
import CommonCrypto

/// Вариант формата канала «gamepad». Протокол не документирован.
struct WireConfig: Codable, Equatable {
    enum Transport: String, Codable, CaseIterable { case tcp, udp }
    enum Framing: String, Codable, CaseIterable {
        case lenOrderEnc
        case lenEncOrder
        case encOrder
        case orderEnc

        var hasLength: Bool { self == .lenOrderEnc || self == .lenEncOrder }
        var title: String {
            switch self {
            case .lenOrderEnc: return "len|order|AES"
            case .lenEncOrder: return "len|AES(order+msg)"
            case .encOrder: return "AES(order+msg)"
            case .orderEnc: return "order|AES"
            }
        }
    }
    enum KeyMode: String, Codable, CaseIterable { case auto, hex, base64, utf8, sha256 }
    enum IVMode: String, Codable, CaseIterable { case uuidBytes, utf8Prefix }

    var transport: Transport = .tcp
    var framing: Framing = .lenOrderEnc
    var keyMode: KeyMode = .auto
    var ivMode: IVMode = .uuidBytes

    static let baseline = WireConfig()
    private static let storeKey = "SaluteRemotePlus.wireConfig"

    var title: String {
        "\(transport.rawValue.uppercased()) · \(framing.title) · key:\(keyMode.rawValue) · iv:\(ivMode.rawValue)"
    }

    static func candidates(for session: GamepadSession) -> [WireConfig] {
        var seenKeys = Set<Data>()
        let keyModes = KeyMode.allCases.filter {
            guard let key = GamepadWire.deriveKey(session.aesKey, $0) else { return false }
            return seenKeys.insert(key).inserted
        }
        var seenIVs = Set<Data>()
        let ivModes = IVMode.allCases.filter {
            guard let value = GamepadWire.deriveIV(session.sessionId, $0) else { return false }
            return seenIVs.insert(value).inserted
        }

        var result: [WireConfig] = []
        for transport in Transport.allCases {
            for framing in Framing.allCases where transport == .udp || framing.hasLength {
                for keyMode in keyModes {
                    for ivMode in ivModes {
                        result.append(WireConfig(transport: transport, framing: framing, keyMode: keyMode, ivMode: ivMode))
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
    private var iv: Data?
    private var hosts: [String] = []
    private var hostIndex = 0
    private var dropRetries = 0
    private var pending: [(Int32, Bool)] = []
    private var sendInFlight = false
    private var order: UInt32 = 0
    private var generation = 0
    private var sentLogged = 0
    // Всё состояние транспорта, читаемое из queue, хранится отдельно от @Published ready.
    private var transportReady = false
    private var openCompletion: ((Bool) -> Void)?

    func prepare(session: GamepadSession) {
        queue.async {
            // resume() и didSet могут вызвать prepare() для одной сессии подряд.
            // Не трогаем рабочее соединение, если параметры сессии не изменились.
            if let current = self.session,
               current.sessionId == session.sessionId,
               current.port == session.port,
               current.serviceVersion == session.serviceVersion,
               current.aesKey == session.aesKey,
               current.ipv4 == session.ipv4,
               self.transportReady,
               self.connection != nil,
               self.key != nil,
               self.iv != nil {
                return
            }

            self.teardownLocked()
            self.session = session
            self.restartLocked()
        }
    }

    /// Открывает канал с выбранной конфигурацией. Completion относится именно к этому запуску.
    func apply(_ newConfig: WireConfig, persist: Bool = true, completion: ((Bool) -> Void)? = nil) {
        if persist { newConfig.save() }
        DispatchQueue.main.async { self.config = newConfig }
        queue.async {
            self.finishOpen(false)
            self.openCompletion = completion
            self.cfg = newConfig
            if self.session != nil {
                self.restartLocked()
            } else {
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

    func press(_ code: Int32) {
        queue.async {
            self.pending.append((code, true))
            self.pending.append((code, false))
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
                self.pending.append((code, true))
                self.pending.append((code, false))
            }
            self.flushIfReady()
        }
        return skipped
    }

    func stop() {
        queue.async {
            self.session = nil
            self.teardownLocked()
            self.finishOpen(false)
        }
    }

    private func teardownLocked() {
        generation += 1
        connection?.cancel()
        connection = nil
        transportReady = false
        setReady(false)
        sendInFlight = false
        pending.removeAll()
        hosts.removeAll()
        hostIndex = 0
    }

    private func restartLocked() {
        teardownLocked()
        guard let session else {
            finishOpen(false)
            return
        }
        key = Self.deriveKey(session.aesKey, cfg.keyMode)
        iv = Self.deriveIV(session.sessionId, cfg.ivMode)
        guard let resolvedKey = key, let resolvedIV = iv else {
            DebugLog.add("⚠️ Ключ/IV не подходят под режим \(cfg.keyMode.rawValue)/\(cfg.ivMode.rawValue) (\(Self.describeKey(session.aesKey)))")
            finishOpen(false)
            return
        }
        DebugLog.add("🔑 Ключ \(resolvedKey.count) Б (\(cfg.keyMode.rawValue)), IV \(resolvedIV.count) Б (\(cfg.ivMode.rawValue)) [\(Self.describeKey(session.aesKey))]")
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
            finishOpen(false)
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
                    DebugLog.add("✓ канал открыт \(host)")
                    self.setReady(true)
                    self.dropRetries = 0
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

    /// Восстанавливает транспорт после обрыва уже открытого канала.
    /// Сначала пробует оставшиеся адреса, затем ограниченно переподключается к первому.
    private func reconnectAfterDrop() {
        connection?.cancel()
        connection = nil
        setReady(false)
        sendInFlight = false
        guard openCompletion == nil, session != nil else { return }

        if hostIndex + 1 < hosts.count {
            hostIndex += 1
            DebugLog.add("↻ TCP оборвался — пробуем следующий адрес (\(hostIndex + 1)/\(hosts.count))")
            openNext()
        } else if !hosts.isEmpty, dropRetries < 2 {
            dropRetries += 1
            hostIndex = 0
            let currentGen = generation
            DebugLog.add("↻ TCP оборвался — повторное подключение к \(hosts[0]) через 0,8 сек (\(dropRetries)/2)")
            queue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self,
                      currentGen == self.generation,
                      self.session != nil,
                      self.connection == nil else { return }
                self.openNext()
            }
        } else {
            DebugLog.add("✖︎ TCP: исчерпаны попытки восстановления канала")
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
                    self.reconnectAfterDrop()
                    return
                }
                if complete && self.cfg.transport == .tcp {
                    DebugLog.add("← ТВ закрыл TCP-соединение")
                    self.reconnectAfterDrop()
                    return
                }
                self.receiveLoop(conn, generation: generation)
            }
        }
    }
    private func flushIfReady() {
        guard transportReady, !sendInFlight, !pending.isEmpty,
              let connection, let key, let iv else { return }

        let item = pending.removeFirst()
        let (code, pressed) = item
        let message = Self.field(1, Self.buttonMessage(code: code, pressed: pressed))
        let orderBytes: Data
        let plaintext: Data

        switch cfg.framing {
        case .lenOrderEnc, .orderEnc:
            if pressed { order &+= 2 }
            orderBytes = Data(Self.be32(order))
            plaintext = message
        case .lenEncOrder, .encOrder:
            order &+= 1
            orderBytes = Data(Self.be32(order))
            plaintext = orderBytes + message
        }

        guard let encrypted = Self.aesCBCEncrypt(plaintext, key: key, iv: iv) else {
            DebugLog.add("✖︎ ошибка шифрования")
            pending.removeAll()
            return
        }

        let payload: Data
        switch cfg.framing {
        case .lenOrderEnc, .orderEnc:
            payload = orderBytes + encrypted
        case .lenEncOrder, .encOrder:
            payload = encrypted
        }

        var packet = Data()
        if cfg.framing.hasLength {
            packet.append(contentsOf: Self.be32(UInt32(payload.count)))
        }
        packet.append(payload)

        sendInFlight = true
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.sendInFlight = false
                if let error {
                    DebugLog.add("✖︎ отправка: \(error.localizedDescription)")
                    self.pending.insert(item, at: 0)
                    self.advance()
                } else {
                    if self.sentLogged < 4 {
                        self.sentLogged += 1
                        DebugLog.add("↑ отправлено \(packet.count) Б (код \(code) \(pressed ? "↓" : "↑"))")
                    }
                    self.flushIfReady()
                }
            }
        })
    }

    private static func buttonMessage(code: Int32, pressed: Bool) -> Data {
        var data = Data([0x08])
        data.append(contentsOf: varint(UInt64(UInt32(bitPattern: code))))
        data.append(contentsOf: [0x10, pressed ? 0x01 : 0x00])
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

    static func deriveIV(_ sessionId: String, _ mode: WireConfig.IVMode) -> Data? {
        switch mode {
        case .uuidBytes:
            guard let uuid = UUID(uuidString: sessionId) else { return nil }
            var raw = uuid.uuid
            return withUnsafeBytes(of: &raw) { Data($0) }
        case .utf8Prefix:
            let data = Data(sessionId.utf8)
            return data.count >= 16 ? data.prefix(16) : nil
        }
    }

    static func decodeBase64Flexible(_ string: String) -> Data? {
        var cleaned = string
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !cleaned.isEmpty else { return nil }
        let remainder = cleaned.count % 4
        if remainder != 0 {
            cleaned.append(String(repeating: "=", count: 4 - remainder))
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

    private static func sha256(_ data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }

    static func deriveKey(_ string: String, _ mode: WireConfig.KeyMode) -> Data? {
        let validLengths = [16, 24, 32]
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch mode {
        case .auto:
            return deriveKey(string, .base64)
                ?? deriveKey(string, .hex)
                ?? deriveKey(string, .utf8)
                ?? deriveKey(string, .sha256)
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
        case .sha256:
            return sha256(Data(trimmed.utf8))
        }
    }

    static func describeKey(_ string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasWhitespace = string.count != trimmed.count
            || trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        let base64Bytes = decodeBase64Flexible(trimmed)?.count
        let hexBytes = decodeHexFlexible(trimmed)?.count
        let symbols = [":", ",", "{", "[", "-", "_"].filter { trimmed.contains($0) }.joined()
        return "len:\(string.count)/trim:\(trimmed.count), ws:\(hasWhitespace ? "да" : "нет"), b64:\(base64Bytes.map(String.init) ?? "—")Б, hex:\(hexBytes.map(String.init) ?? "—")Б, sym:\(symbols.isEmpty ? "—" : symbols)"
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
}
