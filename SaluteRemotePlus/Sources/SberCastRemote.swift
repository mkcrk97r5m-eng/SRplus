import Foundation
import Network
import Security
import LibSberCast
import Combine

/// Хранилище токенов сопряжения в Keychain (чтобы не терять авторизацию между запусками).
private enum DeviceTokenStore {
    private static let service = "com.andrey.saluteremoteplus.sbercast-token"

    static func save(_ token: String, for deviceId: String) {
        guard !token.isEmpty, let data = token.data(using: .utf8) else { return }
        delete(for: deviceId)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(for deviceId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    static func delete(for deviceId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Перенаправление внутренних логов LibSberCast в DebugLog с фильтрацией секретов.
private final class SberCastSDKLogWriter: LibSberCast.SberCastLogWriter {
    func checkSeverity(level: LibSberCast.CastLogSeverity) -> Bool {
        switch level {
        case .fatal, .error, .warning, .info:
            return true
        default:
            return false
        }
    }

    func write(withRecord record: LibSberCast.CastLogRecord) {
        let msg = record.message
        if record.level == .info {
            let interesting =
                msg.contains("connect") ||
                msg.contains("Connect") ||
                msg.contains("Token") ||
                msg.contains("token") ||
                msg.contains("Tls") ||
                msg.contains("tls") ||
                msg.contains("Gamepad") ||
                msg.contains("gamepad") ||
                msg.contains("Follower") ||
                msg.contains("Pin") ||
                msg.contains("pin")
            guard interesting else { return }
        }
        let sanitized = Self.sanitize(msg)
        DebugLog.add("SDK[\(record.level)] \(sanitized)")
    }

    private static func sanitize(_ text: String) -> String {
        let secretMarkers = ["BEGIN CERTIFICATE", "pin_access_token", "pinAccessToken", "aes_key", "aesKey"]
        if secretMarkers.contains(where: { text.contains($0) }) {
            return "<скрыто: содержит секрет>"
        }
        if text.count > 220 {
            return String(text.prefix(220)) + "…"
        }
        return text
    }
}

@MainActor
final class SberCastRemote: NSObject, ObservableObject, LibSberCast.SberCastListener, LibSberCast.VoiceTransportListener {
    @Published private(set) var devices: [LibSberCast.SberCastDevice] = []
    @Published private(set) var status = "Запуск…"
    @Published private(set) var connectedDevice: LibSberCast.SberCastDevice?
    @Published private(set) var session: GamepadSession? {
        didSet { if let s = session { wire.prepare(session: s) } else { wire.stop() } }
    }
    @Published private(set) var wireReady = false
    @Published private(set) var voiceState: VoiceState = .idle
    @Published private(set) var notice: String?
    enum VoiceState: Equatable { case idle, starting, listening }
    let wire = GamepadWire()
    private let mic = MicStreamer()
    @Published var pin: String = ""
    @Published private(set) var needsPin = false
    @Published private(set) var error: String?

    private let cast: any LibSberCast.SberCast
    private let sdkLogWriter = SberCastSDKLogWriter()
    private var activeDeviceID: String?
    private var permissionBrowser: NWBrowser?
    private var autoConnectAttempted = false
    private var started = false
    private var paused = false
    private var gamepadRequestInFlight = false
    private var deviceConnectInFlight = false
    private var awaitingGamepadAfterConnect = false
    private var connectTimeoutTask: Task<Void, Never>?
    private var waitConnectedTask: Task<Void, Never>?
    private var gamepadRetryTask: Task<Void, Never>?
    private var gamepadRetryCount = 0
    private var reconnectRetryCount = 0
    private var wireReconnectCount = 0
    private var restartTask: Task<Void, Never>?
    private var noticeClearTask: Task<Void, Never>?
    private var discoveryRestarts = 0

    private let savedDeviceIDKey = "SaluteRemotePlus.savedDeviceID"
    private let savedDeviceNameKey = "SaluteRemotePlus.savedDeviceName"

    private var lastKnownVolume = 25
    private var lastKnownMuted = false
    private var lastKnownPlaying = false

    override init() {
        self.cast = LibSberCast.SberCastFactory.makeSberCast(clientName: "SaluteRemotePlus")
        super.init()
        cast.setLogWrapper(logWriter: sdkLogWriter)
        cast.setMetaDataUpdatesFilter(filter: [.basic, .volumeInfo, .mediaState])
        cast.addListener(listener: self)
        cast.setClientName(name: "SaluteRemotePlus")
        cast.setClientId(name: "saluteremoteplus")
        _ = cast.voiceTransport.resetListener(listener: self)
        wire.$ready
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in
                self?.wireReady = ready
                if ready { self?.wireReconnectCount = 0 }
            }
            .store(in: &cancellables)
        wire.onReconnectNeeded = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleWireReconnectNeeded()
            }
        }
    }

    private var cancellables = Set<AnyCancellable>()

    private func handleWireReconnectNeeded() {
        guard !paused,
              connectedDevice != nil,
              !needsPin,
              !gamepadRequestInFlight,
              !deviceConnectInFlight else { return }
        wireReconnectCount += 1
        guard wireReconnectCount <= 3 else {
            DebugLog.error("Исчерпан лимит автопереподключений канала пульта (3/3)")
            error = "Канал пульта разорван. Нажмите обновление или откройте диагностику."
            status = "Канал пульта закрыт"
            return
        }
        DebugLog.add("Канал пульта разорван — переподключаемся (попытка \(wireReconnectCount)/3)")
        session = nil
        awaitingGamepadAfterConnect = true
        if isActiveDeviceConnected {
            gamepadRetryCount = 0
            requestGamepadSession()
        } else {
            connectAuthorizedDevice()
        }
    }

    private var activeDeviceFromList: LibSberCast.SberCastDevice? {
        guard let id = activeDeviceID else { return nil }
        return devices.first(where: { $0.id == id })
    }

    private var isActiveDeviceConnected: Bool {
        activeDeviceFromList?.isConnected == true
    }

    private func showNotice(_ text: String?, autoClear: Bool = true) {
        noticeClearTask?.cancel()
        noticeClearTask = nil
        notice = text
        guard autoClear, let text, !text.isEmpty else { return }
        noticeClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self?.notice == text { self?.notice = nil }
            }
        }
    }

    // MARK: - Кнопки, текст, голос
    func send(_ command: RemoteCommand) {
        DebugLog.add("ДЕЙСТВИЕ: кнопка \(command) (код \(command.keyCode))")

        // Громкость, Mute и Play/Pause отправляем напрямую через официальный канал LibSberCast —
        // они работают без зависимости от UDP-протокола gamepad.
        if let id = activeDeviceID, isActiveDeviceConnected {
            switch command {
            case .volumeUp:
                let current = connectedDevice?.metadata?.volume.percent ?? lastKnownVolume
                let next = min(100, current + 1)
                lastKnownVolume = next
                let req = cast.sendRequest(deviceId: id, request: LibSberCast.CastRequest(type: .setVolumeRequest(volumePercentValue: next)))
                DebugLog.add("ЗАПРОС → setVolume(\(next)%), id=\(String(describing: req))")
                showNotice("Громкость: \(next)%")
                return
            case .volumeDown:
                let current = connectedDevice?.metadata?.volume.percent ?? lastKnownVolume
                let next = max(0, current - 1)
                lastKnownVolume = next
                let req = cast.sendRequest(deviceId: id, request: LibSberCast.CastRequest(type: .setVolumeRequest(volumePercentValue: next)))
                DebugLog.add("ЗАПРОС → setVolume(\(next)%), id=\(String(describing: req))")
                showNotice("Громкость: \(next)%")
                return
            case .mute:
                let muted = connectedDevice?.metadata?.volume.muted ?? lastKnownMuted
                let nextMuted = !muted
                lastKnownMuted = nextMuted
                let cmd: LibSberCast.CastRequestType.MediaCommandType = nextMuted ? .mute : .unmute
                let req = cast.sendRequest(deviceId: id, request: LibSberCast.CastRequest(type: .mediaCommandRequest(command: cmd)))
                DebugLog.add("ЗАПРОС → mediaCommand(\(cmd)), id=\(String(describing: req))")
                showNotice(nextMuted ? "Звук выключен" : "Звук включён")
                return
            case .playPause:
                let playing = currentMediaPlaying ?? lastKnownPlaying
                let nextPlaying = !playing
                lastKnownPlaying = nextPlaying
                let cmd: LibSberCast.CastRequestType.MediaCommandType = nextPlaying ? .play : .pause
                let req = cast.sendRequest(deviceId: id, request: LibSberCast.CastRequest(type: .mediaCommandRequest(command: cmd)))
                DebugLog.add("ЗАПРОС → mediaCommand(\(cmd)), id=\(String(describing: req))")
                showNotice(nextPlaying ? "Воспроизведение" : "Пауза")
                return
            case .settings:
                let req = cast.sendDirective(deviceId: id, directive: LibSberCast.CastDirective(.openDeeplink("sberdevices_app_v2://settings")))
                DebugLog.add("ЗАПРОС → openDeeplink(settings), id=\(String(describing: req))")
                showNotice("Открываем настройки ТВ")
                return
            default:
                break
            }
        }

        guard session != nil else {
            showNotice("Канал пульта ещё не готов — переподключаем…", autoClear: false)
            if !gamepadRequestInFlight && !deviceConnectInFlight { reconnectChannel() }
            return
        }
        showNotice(nil)
        wire.press(Int32(command.keyCode))
    }

    func sendDown(_ command: RemoteCommand) {
        DebugLog.add("ДЕЙСТВИЕ: зажатие \(command) (код \(command.keyCode) ↓)")
        guard session != nil else {
            showNotice("Канал пульта ещё не готов — переподключаем…", autoClear: false)
            if !gamepadRequestInFlight && !deviceConnectInFlight { reconnectChannel() }
            return
        }
        showNotice(nil)
        wire.keyDown(Int32(command.keyCode))
    }

    func sendUp(_ command: RemoteCommand) {
        DebugLog.add("ДЕЙСТВИЕ: отпускание \(command) (код \(command.keyCode) ↑)")
        guard session != nil else { return }
        wire.keyUp(Int32(command.keyCode))
    }

    func sendLongPress(_ command: RemoteCommand, duration: TimeInterval = 1.2) {
        DebugLog.add("ДЕЙСТВИЕ: долгое нажатие \(command) (код \(command.keyCode))")
        guard session != nil else {
            showNotice("Канал пульта ещё не готов — переподключаем…", autoClear: false)
            if !gamepadRequestInFlight && !deviceConnectInFlight { reconnectChannel() }
            return
        }
        wire.longPress(Int32(command.keyCode), duration: duration)
    }

    private var currentMediaPlaying: Bool? {
        guard let info = connectedDevice?.metadata?.mediaInfo.playerInfo else { return nil }
        switch info {
        case .music(let player): return player.playing
        case .radio(let player): return player.playing
        case .bluetooth(let player): return player.playing
        case .noPlayer: return nil
        }
    }

    func findRemote() {
        guard let id = activeDeviceID, isActiveDeviceConnected else {
            showNotice("Телевизор не подключён")
            return
        }
        let req = cast.sendRequest(deviceId: id, request: LibSberCast.CastRequest(type: .findRemoteControllerRequest))
        DebugLog.add("ЗАПРОС → findRemoteController, id=\(String(describing: req))")
        showNotice("Отправлен сигнал поиска пульта")
    }

    func sendKey(_ code: Int32) {
        DebugLog.add("ДЕЙСТВИЕ: клавиша клавиатуры \(code)")
        guard session != nil else {
            showNotice("Канал пульта ещё не готов")
            return
        }
        wire.sendKeyboardKey(code)
    }

    /// Повторно запросить у ТВ параметры игрового канала (с проверкой состояния соединения).
    func reconnectChannel() {
        DebugLog.add("ДЕЙСТВИЕ: повторный запрос канала пульта")
        guard connectedDevice != nil, !needsPin else {
            DebugLog.add("Пропуск: ТВ не подключён или ожидается PIN")
            return
        }
        gamepadRetryTask?.cancel()
        gamepadRetryTask = nil
        waitConnectedTask?.cancel()
        waitConnectedTask = nil
        gamepadRequestInFlight = false
        gamepadRetryCount = 0
        reconnectRetryCount = 0
        wireReconnectCount = 0
        awaitingGamepadAfterConnect = true
        error = nil
        session = nil

        if isActiveDeviceConnected {
            requestGamepadSession()
        } else {
            connectAuthorizedDevice()
        }
    }

    /// Отменить подключение, ожидающее PIN-код.
    func cancelPin() {
        DebugLog.add("ДЕЙСТВИЕ: отмена сопряжения")
        if let id = activeDeviceID { _ = cast.cancelDeviceConnectionRequest(deviceId: id) }
        cancelPendingConnectionTasks()
        needsPin = false
        pin = ""
        connectedDevice = nil
        activeDeviceID = nil
        session = nil
        status = "Подключение отменено"
    }

    private func cancelPendingConnectionTasks() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        waitConnectedTask?.cancel()
        waitConnectedTask = nil
        gamepadRetryTask?.cancel()
        gamepadRetryTask = nil
        deviceConnectInFlight = false
        gamepadRequestInFlight = false
        awaitingGamepadAfterConnect = false
    }

    private func scheduleDiscoveryRestart() {
        guard discoveryRestarts < 5 else {
            error = "Нет доступа к локальной сети. Проверьте Настройки → Конфиденциальность → Локальная сеть → Salute Remote+"
            return
        }
        discoveryRestarts += 1
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.paused, self.started, self.connectedDevice == nil else { return }
                DebugLog.add("Перезапуск поиска (попытка \(self.discoveryRestarts))")
                self.cast.stop()
                self.cast.start()
            }
        }
    }

    func typeText(_ text: String, submit: Bool) {
        DebugLog.add("ДЕЙСТВИЕ: ввод текста, символов \(text.count), Enter: \(submit) (сам текст не записывается)")
        guard session != nil else {
            showNotice("Канал пульта ещё не готов")
            return
        }
        wire.typeSymbols(text)
        if submit { wire.sendKeyboardKey(KeyMap.enter) }
        showNotice(nil)
    }

    func youtubeSearch(_ text: String) {
        DebugLog.add("ЗАПРОС → YouTube search, символов: \(text.count)")
        guard let id = activeDeviceID, !text.isEmpty else {
            DebugLog.error("YouTube search: нет устройства или пустой запрос")
            return
        }
        let request = cast.sendDirective(deviceId: id, directive: LibSberCast.CastDirective(.showYouTubeSearchDirective(textToSearch: text)))
        DebugLog.add("YouTube search request id: \(String(describing: request))")
    }

    func toggleVoice() {
        DebugLog.add("ДЕЙСТВИЕ: переключение голосового ввода")
        voiceState == .idle ? startVoice() : cancelVoice()
    }

    private func startVoice() {
        DebugLog.add("ЗАПРОС → запуск голосового ввода")
        guard let id = activeDeviceID, connectedDevice != nil else {
            DebugLog.error("Голос: телевизор не подключён")
            notice = "Телевизор не подключён"
            return
        }
        MicStreamer.requestPermission { [weak self] granted in
            DebugLog.add("ОТВЕТ iOS: разрешение микрофона = \(granted)")
            guard let self else { return }
            guard granted else { self.error = "Нет доступа к микрофону — разрешите в Настройках iOS"; return }
            self.error = nil; self.notice = nil; self.voiceState = .starting
            self.cast.voiceTransport.startVoiceInput(deviceId: id)
        }
    }

    private func cancelVoice() {
        DebugLog.add("ДЕЙСТВИЕ: остановка голосового ввода")
        if let id = activeDeviceID { cast.voiceTransport.cancelVoiceInput(deviceId: id) }
        endVoice()
    }

    private func endVoice() { mic.stop(); voiceState = .idle }

    private func beginStreaming(deviceId: String) {
        DebugLog.add("ГОЛОС: начало передачи аудио")
        let transport = cast.voiceTransport
        do {
            try mic.start { chunk in
                transport.sendAudioData(deviceId: deviceId, audioType: .pcm16khz16bit, audioData: chunk)
            }
            voiceState = .listening
        } catch {
            DebugLog.error("Микрофон: \(error.localizedDescription)")
            self.error = "Микрофон: \(error.localizedDescription)"
            cancelVoice()
        }
    }

    private func handleVoice(deviceId: String, status: LibSberCast.VoiceTransportConversationStatus) {
        DebugLog.add("ОТВЕТ ТВ ← voice status: \(status)")
        switch status {
        case .listening: if voiceState == .starting { beginStreaming(deviceId: deviceId) }
        case .listeningComplete, .ended, .cancelled: endVoice()
        case .error, .deviceNotConnected: error = "Голосовой ввод недоступен на этом ТВ"; endVoice()
        case .notStarted, .unknown: break
        }
    }

    nonisolated func onStartVoiceInputResponse(deviceId: String, status: LibSberCast.VoiceTransportConversationStatus) {
        Task { @MainActor [weak self] in self?.handleVoice(deviceId: deviceId, status: status) }
    }
    nonisolated func onSendAudioDataResponse(deviceId: String, status: LibSberCast.VoiceTransportConversationStatus) {
        Task { @MainActor [weak self] in self?.handleVoice(deviceId: deviceId, status: status) }
    }
    nonisolated func onCancelVoiceInputResponse(deviceId: String, status: LibSberCast.VoiceTransportConversationStatus) {
        Task { @MainActor [weak self] in self?.endVoice() }
    }

    var hasSavedDevice: Bool {
        UserDefaults.standard.string(forKey: savedDeviceIDKey) != nil
    }

    func start() {
        DebugLog.add("ЖИЗНЕННЫЙ ЦИКЛ: start()")
        guard !started else { DebugLog.add("start пропущен: уже запущено"); return }
        started = true
        paused = false
        error = nil
        autoConnectAttempted = false
        gamepadRetryCount = 0
        reconnectRetryCount = 0
        status = hasSavedDevice ? "Восстанавливаем телевизор…" : "Подключаемся к локальной сети…"
        startBonjourPermissionProbe()
    }

    func resume() {
        if started && !paused {
            return
        }
        DebugLog.add("ЖИЗНЕННЫЙ ЦИКЛ: приложение активно, resume()")
        paused = false
        if !started {
            start()
            return
        }

        if cast.isPaused || !cast.isRunning {
            DebugLog.add("Возобновляем SberCast (isPaused=\(cast.isPaused), isRunning=\(cast.isRunning))")
            cast.start()
        }

        if connectedDevice != nil {
            if let s = session {
                if wire.ready {
                    wire.resumeKeepalive()
                } else {
                    wire.prepare(session: s)
                }
            }
            reconnectGamepadIfNeeded()
        } else {
            reconnectSavedDeviceIfPossible()
        }
    }

    func pause() {
        guard !paused else { return }
        DebugLog.add("ЖИЗНЕННЫЙ ЦИКЛ: приложение уходит в фон, pause()")
        paused = true
        wire.pauseKeepalive()
        if voiceState != .idle { cancelVoice() }
        restartTask?.cancel()
        restartTask = nil
        permissionBrowser?.cancel()
        permissionBrowser = nil
        if cast.isRunning && !cast.isPaused {
            cast.pause()
        }
    }

    private func startBonjourPermissionProbe() {
        guard !paused, permissionBrowser == nil else { return }

        let browser = NWBrowser(
            for: .bonjour(type: "_staros._tcp", domain: "local."),
            using: .tcp
        )
        permissionBrowser = browser
        browser.stateUpdateHandler = { [weak self] state in
            DebugLog.add("Bonjour browser state: \(state)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.permissionBrowser?.cancel()
                    self.permissionBrowser = nil
                    guard !self.paused else { return }
                    self.status = self.hasSavedDevice ? "Ищем сохранённый телевизор…" : "Ищем телевизор…"
                    if !self.cast.isRunning || self.cast.isPaused {
                        self.cast.start()
                    }
                case .failed(let error):
                    DebugLog.error("Bonjour browser: \(error.localizedDescription), code=\(error.errorCode)")
                    self.permissionBrowser?.cancel()
                    self.permissionBrowser = nil
                    guard !self.paused else { return }

                    self.error = "Доступ к локальной сети: \(error.localizedDescription) (код \(error.errorCode))"
                    self.status = self.hasSavedDevice ? "Ищем сохранённый телевизор…" : "Ищем телевизор…"
                    if !self.cast.isRunning || self.cast.isPaused {
                        self.cast.start()
                    }
                case .cancelled:
                    self.permissionBrowser = nil
                default:
                    break
                }
            }
        }
        browser.start(queue: DispatchQueue(label: "SaluteRemotePlus.LocalNetwork"))
    }

    func stop() {
        DebugLog.add("ДЕЙСТВИЕ: остановка клиента и обнаружения")
        restartTask?.cancel()
        restartTask = nil
        cancelPendingConnectionTasks()
        permissionBrowser?.cancel()
        permissionBrowser = nil
        cast.stop()
        started = false
        paused = false
        status = hasSavedDevice ? "Остановлено — телевизор сохранён" : "Остановлено"
    }

    private func resolvedAccessToken(for deviceId: String) -> String {
        let sdkToken = cast.accessTokenForDevice(deviceId)
        if !sdkToken.isEmpty { return sdkToken }
        if let stored = DeviceTokenStore.load(for: deviceId) {
            cast.setAccessTokenForDevice(deviceId, accessToken: stored)
            return stored
        }
        return ""
    }

    func connect(_ device: LibSberCast.SberCastDevice, save: Bool = true) {
        DebugLog.add("ДЕЙСТВИЕ: подключение к устройству \(device.name), id=\(device.id), connected=\(device.isConnected), save=\(save)")
        cancelPendingConnectionTasks()
        gamepadRetryCount = 0
        reconnectRetryCount = 0
        session = nil

        activeDeviceID = device.id
        connectedDevice = device
        needsPin = false
        pin = ""
        error = nil

        if save {
            UserDefaults.standard.set(device.id, forKey: savedDeviceIDKey)
            UserDefaults.standard.set(device.name, forKey: savedDeviceNameKey)
        }

        let token = resolvedAccessToken(for: device.id)
        DebugLog.add("Токен устройства: \(token.isEmpty ? "отсутствует (потребуется PIN)" : "найден (\(token.count) симв.)")")

        if device.isConnected && !token.isEmpty {
            awaitingGamepadAfterConnect = true
            requestGamepadSession()
            return
        }

        startConnectToDevice(deviceId: device.id, token: token, statusText: "Подключаемся к \(device.name)…")
    }

    func reconnectSavedDeviceIfPossible() {
        guard !autoConnectAttempted,
              let savedID = UserDefaults.standard.string(forKey: savedDeviceIDKey),
              let device = devices.first(where: { $0.id == savedID }) else { return }
        autoConnectAttempted = true
        connect(device, save: false)
    }

    private func reconnectGamepadIfNeeded() {
        guard connectedDevice != nil, session == nil, !needsPin else { return }
        awaitingGamepadAfterConnect = true
        if isActiveDeviceConnected {
            if !gamepadRequestInFlight {
                gamepadRetryCount = 0
                requestGamepadSession()
            }
        } else {
            connectAuthorizedDevice()
        }
    }

    private func connectAuthorizedDevice() {
        guard let id = activeDeviceID,
              connectedDevice != nil,
              !needsPin,
              !deviceConnectInFlight else { return }
        let token = resolvedAccessToken(for: id)
        awaitingGamepadAfterConnect = true
        startConnectToDevice(deviceId: id, token: token, statusText: "Завершаем подключение к телевизору…")
    }

    private func startConnectToDevice(deviceId: String, token: String, statusText: String) {
        gamepadRetryTask?.cancel()
        gamepadRetryTask = nil
        waitConnectedTask?.cancel()
        waitConnectedTask = nil
        gamepadRequestInFlight = false
        deviceConnectInFlight = true
        status = statusText

        if !token.isEmpty {
            cast.setAccessTokenForDevice(deviceId, accessToken: token)
        }
        let requestID = cast.connectToDevice(deviceId: deviceId, accessToken: token)
        DebugLog.add("ЗАПРОС → connectToDevice, request id: \(String(describing: requestID)); токен \(token.isEmpty ? "пустой" : "задан")")

        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.deviceConnectInFlight else { return }
                self.deviceConnectInFlight = false
                DebugLog.error("Таймаут connectToDevice (8 сек)")
                if self.isActiveDeviceConnected && self.session == nil && !self.needsPin {
                    self.requestGamepadSession()
                } else {
                    self.error = "Телевизор не ответил на подключение"
                    self.status = "Таймаут подключения"
                }
            }
        }
    }

    private func scheduleGamepadSessionWhenConnected() {
        awaitingGamepadAfterConnect = true
        if isActiveDeviceConnected {
            requestGamepadSession()
            return
        }
        status = "Ждём защищённое подключение к ТВ…"
        DebugLog.add("Ждём isConnected=true от SDK перед запросом getGamepadSession…")
        waitConnectedTask?.cancel()
        waitConnectedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.awaitingGamepadAfterConnect,
                      self.session == nil,
                      !self.needsPin,
                      !self.gamepadRequestInFlight else { return }

                if self.isActiveDeviceConnected {
                    self.requestGamepadSession()
                    return
                }

                // Не шлём getGamepadSession в неподключённый ТВ: пробуем восстановить
                // авторизованное соединение с сохранённым токеном.
                if !self.deviceConnectInFlight, self.reconnectRetryCount < 3 {
                    self.reconnectRetryCount += 1
                    DebugLog.error("ТВ не перешёл в isConnected=true за 5 сек — повторяем connectToDevice (\(self.reconnectRetryCount)/3)")
                    self.connectAuthorizedDevice()
                } else {
                    self.awaitingGamepadAfterConnect = false
                    DebugLog.error("ТВ так и не установил защищённое соединение (isConnected=false)")
                    self.error = "Телевизор не установил защищённое подключение. Попробуйте переподключиться."
                    self.status = "Нет защищённого соединения с ТВ"
                }
            }
        }
    }

    func forgetSavedDevice() {
        DebugLog.add("ДЕЙСТВИЕ: забыть сохранённый телевизор")
        if let savedID = UserDefaults.standard.string(forKey: savedDeviceIDKey) {
            DeviceTokenStore.delete(for: savedID)
        }
        if let activeID = activeDeviceID {
            DeviceTokenStore.delete(for: activeID)
        }
        cancelPendingConnectionTasks()
        UserDefaults.standard.removeObject(forKey: savedDeviceIDKey)
        UserDefaults.standard.removeObject(forKey: savedDeviceNameKey)
        if voiceState != .idle { cancelVoice() }
        session = nil
        connectedDevice = nil
        activeDeviceID = nil
        needsPin = false
        pin = ""
        error = nil
        reconnectRetryCount = 0
        gamepadRetryCount = 0
        wireReconnectCount = 0
        status = "Телевизор отвязан"
    }

    func confirmPIN() {
        guard let id = activeDeviceID else { return }
        let code = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        pin = code
        error = nil
        status = "Проверяем код…"
        DebugLog.add("ЗАПРОС → подтверждение PIN (\(code.count) символов; значение скрыто)")
        let requestID = cast.confirmDeviceConnectionCode(deviceId: id, code: code)
        DebugLog.add("PIN request id: \(String(describing: requestID))")
    }

    private func requestGamepadSession() {
        guard let id = activeDeviceID, !gamepadRequestInFlight else { return }
        guard isActiveDeviceConnected else {
            DebugLog.add("Отложен getGamepadSession: ТВ ещё не в состоянии isConnected=true")
            scheduleGamepadSessionWhenConnected()
            return
        }
        waitConnectedTask?.cancel()
        waitConnectedTask = nil
        gamepadRequestInFlight = true
        let sid = UUID().uuidString.lowercased()
        status = "Запускаем канал пульта…"
        DebugLog.add("ЗАПРОС → getGamepadSession, sessionId=\(sid), isConnected=true")
        let requestID = cast.sendRequest(
            deviceId: id,
            request: LibSberCast.CastRequest(type: .getGamepadSessionCastRequest(sessionId: sid))
        )
        DebugLog.add("getGamepadSession request id: \(String(describing: requestID))")

        gamepadRetryTask?.cancel()
        gamepadRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await MainActor.run {
                guard self.gamepadRequestInFlight, self.session == nil else { return }
                self.gamepadRequestInFlight = false
                guard self.isActiveDeviceConnected else {
                    self.scheduleGamepadSessionWhenConnected()
                    return
                }
                self.gamepadRetryCount += 1
                if self.gamepadRetryCount <= 5 {
                    self.requestGamepadSession()
                } else {
                    self.error = "Телевизор не вернул параметры канала пульта"
                    self.status = self.connectedDevice == nil ? "Телевизор сохранён, но не подключён" : "Не удалось запустить канал пульта"
                }
            }
        }
    }

    // MARK: - LibSberCast.SberCastListener (nonisolated → @MainActor)

    nonisolated func onStatusChanged(status: LibSberCast.CastStatus) {
        Task { @MainActor [weak self] in self?.handleStatusChanged(status) }
    }

    nonisolated func onError(error: LibSberCast.CastError) {
        Task { @MainActor [weak self] in self?.handleError(error) }
    }

    nonisolated func onDevicesChanged(_ devices: [LibSberCast.SberCastDevice]) {
        Task { @MainActor [weak self] in self?.handleDevicesChanged(devices) }
    }

    nonisolated func onCastMessageResponse(message: LibSberCast.CastMessage) {
        Task { @MainActor [weak self] in self?.handleCastMessageResponse(message) }
    }

    nonisolated func onCastRequestResponse(response: LibSberCast.CastRequestResponse) {
        Task { @MainActor [weak self] in self?.handleCastRequestResponse(response) }
    }

    nonisolated func onBLEDeeplinkReceived(deeplink: String) {
        Task { @MainActor in
            DebugLog.add("ОТВЕТ SDK ← BLE deeplink получен (содержимое скрыто)")
        }
    }

    nonisolated func onBLEDeeplinkRunInfo(_ info: LibSberCast.RunBLEDeeplinkOnDeviceInfo) {
        Task { @MainActor in
            DebugLog.add("ОТВЕТ SDK ← BLE deeplink run info: \(info)")
        }
    }

    // MARK: - MainActor handlers

    private func handleStatusChanged(_ status: LibSberCast.CastStatus) {
        DebugLog.add("ОТВЕТ SDK ← CastStatus: \(status.state), startError: \(status.startError)")
        switch status.state {
        case .stopped: self.status = hasSavedDevice ? "Телевизор сохранён" : "Остановлено"
        case .starting: self.status = "Запускаем обнаружение…"
        case .running:
            if connectedDevice == nil {
                self.status = hasSavedDevice ? "Ищем сохранённый телевизор…" : "Ищем телевизор…"
            }
        }
    }

    private func handleError(_ error: LibSberCast.CastError) {
        DebugLog.error("SberCast callback [\(error.code)]: \(error.msg)")
        if error.msg.contains("-72000") {
            if connectedDevice != nil {
                DebugLog.add("Bonjour -72000: сохраняем экземпляр SberCast, discovery не перезапускаем")
                return
            }
            scheduleDiscoveryRestart()
            return
        }
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        deviceConnectInFlight = false
        gamepadRequestInFlight = false
        self.error = error.msg
        self.status = hasSavedDevice ? "Ошибка подключения — телевизор сохранён" : "Ошибка подключения"
    }

    private func handleDevicesChanged(_ devices: [LibSberCast.SberCastDevice]) {
        let summary = devices.map {
            let gp = $0.features?.contains(.gamepadService) == true || $0.metadata?.hasGamepad == true
            return "\($0.name)(conn:\($0.isConnected),disc:\($0.isDiscovered),gp:\(gp))"
        }.joined(separator: ", ")
        DebugLog.add("ОТВЕТ SDK ← список устройств: \(devices.count) шт. [\(summary)]")

        self.devices = devices
        if !devices.isEmpty {
            discoveryRestarts = 0
            if error?.contains("локальной сети") == true { error = nil }
        }
        if devices.isEmpty {
            if connectedDevice == nil {
                status = hasSavedDevice ? "Ищем сохранённый телевизор…" : "Телевизор не найден"
            }
            return
        }

        if let id = activeDeviceID, let updated = devices.first(where: { $0.id == id }) {
            let wasConnected = connectedDevice?.isConnected == true
            connectedDevice = updated

            if let meta = updated.metadata {
                lastKnownVolume = meta.volume.percent
                lastKnownMuted = meta.volume.muted
                if let playing = currentMediaPlaying {
                    lastKnownPlaying = playing
                }
            }

            if updated.isConnected && !wasConnected {
                DebugLog.add("✓ ТВ перешёл в состояние isConnected=true")
            } else if !updated.isConnected && wasConnected {
                DebugLog.add("⚠️ ТВ перешёл в состояние isConnected=false")
            }

            if updated.isConnected,
               awaitingGamepadAfterConnect,
               session == nil,
               !needsPin,
               !gamepadRequestInFlight {
                connectTimeoutTask?.cancel()
                connectTimeoutTask = nil
                deviceConnectInFlight = false
                requestGamepadSession()
            }
        }

        if !autoConnectAttempted { reconnectSavedDeviceIfPossible() }
        if connectedDevice == nil && !hasSavedDevice { status = "Выберите телевизор" }
    }

    private func handleCastMessageResponse(_ message: LibSberCast.CastMessage) {
        DebugLog.add("ОТВЕТ SDK ← CastMessage: code=\(message.code), description=\(message.description)")
        if message.code != .success {
            DebugLog.error("CastMessage: \(message.description)")
            error = message.description
        }
    }

    private func handleCastRequestResponse(_ response: LibSberCast.CastRequestResponse) {
        switch response.type {
        case .pinConnectConfirmationCastResponse(let deviceId, let pinStatus, _):
            DebugLog.add("ОТВЕТ SDK ← CastRequestResponse: code=\(response.code), type=pinConnectConfirmation(deviceId: \(deviceId), status: \(pinStatus), pinAccessToken: <скрыт>)")
        case .gamepadSessionConnectionInfoCastResponse(let deviceId, let status, let sessionId, let port, let serviceVersion, _, let ipV4List):
            DebugLog.add("ОТВЕТ SDK ← CastRequestResponse: code=\(response.code), type=gamepadSession(deviceId: \(deviceId), status: \(status), sessionId: \(sessionId), port: \(port), version: \(serviceVersion), aesKey: <скрыт>, ip: \(ipV4List))")
        default:
            DebugLog.add("ОТВЕТ SDK ← CastRequestResponse: code=\(response.code), type=\(response.type)")
        }

        if case .pinConnectConfirmationCastResponse(let deviceId, let pinStatus, let token) = response.type {
            activeDeviceID = deviceId
            DebugLog.add("PIN response: request=\(response.code), status=\(pinStatus)")

            guard response.code == .success else {
                DebugLog.error("PIN confirmation rejected: status=\(pinStatus), code=\(response.code)")
                error = "ТВ отклонил подтверждение: \(pinStatus) (\(response.code))"
                status = "Не удалось подтвердить подключение"
                return
            }

            switch pinStatus {
            case .authorized:
                DeviceTokenStore.save(token, for: deviceId)
                cast.setAccessTokenForDevice(deviceId, accessToken: token)
                needsPin = false
                pin = ""
                error = nil
                gamepadRetryCount = 0
                reconnectRetryCount = 0
                awaitingGamepadAfterConnect = true
                connectAuthorizedDevice()
            case .wrongPin:
                DebugLog.error("Телевизор вернул wrongPin")
                error = "Телевизор вернул wrongPin. Проверьте, что код не обновился на экране ТВ."
                status = "Телевизор отклонил код"
            case .attemptsLimitReached:
                DebugLog.error("Исчерпан лимит попыток PIN")
                error = "Телевизор ограничил попытки ввода кода. Запросите новый код на ТВ."
                status = "Лимит попыток исчерпан"
            case .badSessionIdentifiers:
                DebugLog.error("Устаревшие идентификаторы сеанса сопряжения")
                error = "Сеанс сопряжения устарел. Начните подключение заново."
                status = "Сеанс сопряжения истёк"
            case .disabled:
                DebugLog.error("PIN pairing disabled by TV")
                error = "Подключение по PIN отключено на телевизоре."
                status = "Сопряжение отключено"
            case .error:
                DebugLog.error("Generic PIN confirmation error from TV")
                error = "Телевизор вернул ошибку подтверждения PIN."
                status = "Ошибка сопряжения"
            }
            return
        }

        guard response.code == .success else {
            gamepadRequestInFlight = false
            gamepadRetryTask?.cancel()
            gamepadRetryTask = nil

            if !deviceConnectInFlight,
               connectedDevice != nil,
               !needsPin,
               (response.code == .deviceNotConnected || response.code == .unknownDevice) {
                session = nil
                reconnectRetryCount += 1
                if reconnectRetryCount <= 4 {
                    DebugLog.error("SDK не подключён к ТВ (\(response.code)), попытка восстановления \(reconnectRetryCount)/4")
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            guard let self, self.connectedDevice != nil, !self.needsPin else { return }
                            if self.isActiveDeviceConnected {
                                self.requestGamepadSession()
                            } else {
                                self.connectAuthorizedDevice()
                            }
                        }
                    }
                    return
                }
            }

            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            deviceConnectInFlight = false
            DebugLog.error("Cast request rejected: \(response.code)")
            error = "Запрос к телевизору отклонён (\(response.code))"
            status = connectedDevice == nil ? "Телевизор сохранён, но недоступен" : "Ошибка подключения"
            return
        }

        switch response.type {
        case .pinConnectCastResponse(let deviceId, let status):
            activeDeviceID = deviceId
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            deviceConnectInFlight = false

            switch status {
            case .inputPinCode:
                awaitingGamepadAfterConnect = false
                needsPin = true
                error = nil
                self.status = "Введите код с телевизора"
            case .authorized, .sessionAlreadyActive:
                needsPin = false
                error = nil
                gamepadRetryCount = 0
                scheduleGamepadSessionWhenConnected()
            default:
                awaitingGamepadAfterConnect = false
                error = "Телевизор отклонил подключение (\(status))"
                self.status = "Ошибка подключения"
            }

        case .gamepadSessionConnectionInfoCastResponse(let deviceId, let status, let sessionId, let port, let serviceVersion, let aesKey, let ipV4List):
            gamepadRequestInFlight = false
            gamepadRetryTask?.cancel()
            gamepadRetryTask = nil

            guard status == .success else {
                session = nil
                DebugLog.error("Gamepad session failed: \(status)")
                error = "Канал пульта: \(status)"
                self.status = "Канал пульта недоступен — повторяем…"
                gamepadRetryCount += 1
                if gamepadRetryCount <= 5 { requestGamepadSession() }
                return
            }

            guard !sessionId.isEmpty, port > 0, !aesKey.isEmpty, !ipV4List.isEmpty else {
                session = nil
                DebugLog.error("Gamepad response has incomplete session parameters")
                error = "Телевизор вернул неполные параметры канала пульта"
                self.status = "Неполные параметры канала — повторяем…"
                gamepadRetryCount += 1
                if gamepadRetryCount <= 5 { requestGamepadSession() }
                return
            }

            activeDeviceID = deviceId
            awaitingGamepadAfterConnect = false
            gamepadRetryCount = 0
            reconnectRetryCount = 0
            error = nil
            notice = nil
            DebugLog.add("Сессия пульта: порт \(port), версия \(serviceVersion), адреса \(ipV4List.joined(separator: ","))")
            session = GamepadSession(
                sessionId: sessionId,
                port: port,
                serviceVersion: serviceVersion,
                aesKey: aesKey,
                ipv4: Array(ipV4List)
            )
            self.status = "Пульт подключён"

        default:
            break
        }
    }
}
