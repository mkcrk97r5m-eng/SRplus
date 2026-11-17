import Foundation
import Network
import LibSberCast
import Combine

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
    private var activeDeviceID: String?
    private var permissionBrowser: NWBrowser?
    private var autoConnectAttempted = false
    private var started = false
    private var paused = false
    private var gamepadRequestInFlight = false
    private var gamepadRetryTask: Task<Void, Never>?
    private var gamepadRetryCount = 0
    private var restartTask: Task<Void, Never>?
    private var discoveryRestarts = 0

    private let savedDeviceIDKey = "SaluteRemotePlus.savedDeviceID"
    private let savedDeviceNameKey = "SaluteRemotePlus.savedDeviceName"

    override init() {
        self.cast = LibSberCast.SberCastFactory.makeSberCast(clientName: "SaluteRemotePlus")
        super.init()
        cast.addListener(listener: self)
        cast.setClientName(name: "SaluteRemotePlus")
        cast.setClientId(name: "saluteremoteplus")
        _ = cast.voiceTransport.resetListener(listener: self)
        wire.$ready.receive(on: DispatchQueue.main).assign(to: &$wireReady)
    }

    // MARK: - Кнопки, текст, голос
    func send(_ command: RemoteCommand) {
        DebugLog.add("ДЕЙСТВИЕ: кнопка \(command) (код \(command.keyCode))")
        guard session != nil else {
            notice = "Канал пульта ещё не готов — переподключаем…"
            if !gamepadRequestInFlight { reconnectChannel() }
            return
        }
        notice = nil
        wire.press(Int32(command.keyCode))
    }

    func sendKey(_ code: Int32) {
        DebugLog.add("ДЕЙСТВИЕ: клавиша \(code)")
        wire.press(code)
    }

    /// Повторно запросить у ТВ параметры игрового канала.
    func reconnectChannel() {
        DebugLog.add("ДЕЙСТВИЕ: повторный запрос канала пульта")
        guard connectedDevice != nil, !needsPin else { DebugLog.add("Пропуск: ТВ не подключён или ожидается PIN"); return }
        gamepadRetryTask?.cancel()
        gamepadRequestInFlight = false
        gamepadRetryCount = 0
        error = nil
        session = nil
        requestGamepadSession()
    }

    /// Отменить подключение, ожидающее PIN-код.
    func cancelPin() {
        DebugLog.add("ДЕЙСТВИЕ: отмена сопряжения")
        if let id = activeDeviceID { _ = cast.cancelDeviceConnectionRequest(deviceId: id) }
        needsPin = false
        pin = ""
        connectedDevice = nil
        activeDeviceID = nil
        session = nil
        status = "Подключение отменено"
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
                guard let self, !self.paused, self.started else { return }
                DebugLog.add("Перезапуск поиска (попытка \(self.discoveryRestarts))")
                self.cast.stop()
                self.cast.start()
            }
        }
    }
    func typeText(_ text: String, submit: Bool) {
        DebugLog.add("ДЕЙСТВИЕ: ввод текста, символов \(text.count), Enter: \(submit) (сам текст не записывается)")
        guard session != nil else { notice = "Канал пульта ещё не готов"; return }
        let skipped = wire.type(text)
        if submit { wire.press(KeyMap.enter) }
        notice = skipped.isEmpty ? nil : "Не удалось набрать: \(String(skipped)) — используйте голос или поиск YouTube"
    }
    func youtubeSearch(_ text: String) {
        DebugLog.add("ЗАПРОС → YouTube search, символов: \(text.count)")
        guard let id = activeDeviceID, !text.isEmpty else { DebugLog.error("YouTube search: нет устройства или пустой запрос"); return }
        let request = cast.sendDirective(deviceId: id, directive: LibSberCast.CastDirective(.showYouTubeSearchDirective(textToSearch: text)))
        DebugLog.add("YouTube search request id: \(String(describing: request))")
    }
    func toggleVoice() {
        DebugLog.add("ДЕЙСТВИЕ: переключение голосового ввода")
        voiceState == .idle ? startVoice() : cancelVoice()
    }
    private func startVoice() {
        DebugLog.add("ЗАПРОС → запуск голосового ввода")
        guard let id = activeDeviceID, connectedDevice != nil else { DebugLog.error("Голос: телевизор не подключён"); notice = "Телевизор не подключён"; return }
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
        Task { @MainActor in self.handleVoice(deviceId: deviceId, status: status) }
    }
    nonisolated func onSendAudioDataResponse(deviceId: String, status: LibSberCast.VoiceTransportConversationStatus) {
        Task { @MainActor in self.handleVoice(deviceId: deviceId, status: status) }
    }
    nonisolated func onCancelVoiceInputResponse(deviceId: String, status: LibSberCast.VoiceTransportConversationStatus) {
        Task { @MainActor in self.endVoice() }
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
        status = hasSavedDevice ? "Восстанавливаем телевизор…" : "Подключаемся к локальной сети…"
        startBonjourPermissionProbe()
    }

    func resume() {
        DebugLog.add("ЖИЗНЕННЫЙ ЦИКЛ: приложение активно, resume()")
        paused = false
        if !started {
            start()
            return
        }

        // Do not create a second Bonjour browser when returning from background.
        // The SberCast instance remains alive; only the permission probe is recreated
        // if iOS cancelled it while the app was inactive.
        if permissionBrowser == nil && connectedDevice == nil {
            startBonjourPermissionProbe()
        } else if connectedDevice != nil {
            if let s = session, !wire.ready { wire.prepare(session: s) }
            reconnectGamepadIfNeeded()
        } else {
            reconnectSavedDeviceIfPossible()
        }
    }

    func pause() {
        DebugLog.add("ЖИЗНЕННЫЙ ЦИКЛ: приложение уходит в фон, pause()")
        paused = true
        if voiceState != .idle { cancelVoice() }
        // Keep LibSberCast alive across background/foreground transitions.
        // Recreating it here causes Bonjour service errors on the next appearance.
        permissionBrowser?.cancel()
        permissionBrowser = nil
    }

    private func startBonjourPermissionProbe() {
        guard !paused, permissionBrowser == nil else { return }

        let browser = NWBrowser(
            for: .bonjour(type: "_staros._tcp", domain: "local."),
            using: .tcp
        )
        permissionBrowser = browser
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.permissionBrowser?.cancel()
                    self.permissionBrowser = nil
                    guard !self.paused else { return }
                    self.status = self.hasSavedDevice ? "Ищем сохранённый телевизор…" : "Ищем телевизор…"
                    self.cast.start()
                case .failed(let error):
                    self.permissionBrowser?.cancel()
                    self.permissionBrowser = nil
                    guard !self.paused else { return }

                    // The probe is only used to trigger iOS Local Network permission.
                    // It must never block LibSberCast discovery: the previous working
                    // implementation started the SDK even when NWBrowser failed.
                    self.error = "Доступ к локальной сети: \(error.localizedDescription) (код \(error.errorCode))"
                    self.status = self.hasSavedDevice ? "Ищем сохранённый телевизор…" : "Ищем телевизор…"
                    self.cast.start()
                case .cancelled:
                    self.permissionBrowser = nil
                default:
                    break
                }
            }
        }
        browser.start(queue: DispatchQueue(label: "SaluteRemotePlus.LocalNetwork"))
    }

    private func scheduleBonjourRetry() {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.paused, self.started else { return }
                if self.permissionBrowser == nil && self.connectedDevice == nil {
                    self.startBonjourPermissionProbe()
                }
            }
        }
    }

    func stop() {
        DebugLog.add("ДЕЙСТВИЕ: остановка клиента и обнаружения")
        restartTask?.cancel()
        restartTask = nil
        gamepadRetryTask?.cancel()
        gamepadRetryTask = nil
        gamepadRequestInFlight = false
        permissionBrowser?.cancel()
        permissionBrowser = nil
        cast.stop()
        started = false
        paused = false
        status = hasSavedDevice ? "Остановлено — телевизор сохранён" : "Остановлено"
    }

    func connect(_ device: LibSberCast.SberCastDevice, save: Bool = true) {
        DebugLog.add("ДЕЙСТВИЕ: подключение к устройству \(device.name), id=\(device.id), save=\(save)")
        gamepadRetryTask?.cancel()
        gamepadRetryTask = nil
        gamepadRequestInFlight = false
        gamepadRetryCount = 0
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

        status = "Подключаемся к \(device.name)…"
        let token = cast.accessTokenForDevice(device.id)
        let requestID = cast.connectToDevice(deviceId: device.id, accessToken: token)
        DebugLog.add("ЗАПРОС → connectToDevice, request id: \(String(describing: requestID)); token не логируется")
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
        if !gamepadRequestInFlight {
            gamepadRetryCount = 0
            requestGamepadSession()
        }
    }

    func forgetSavedDevice() {
        DebugLog.add("ДЕЙСТВИЕ: забыть сохранённый телевизор")
        gamepadRetryTask?.cancel()
        gamepadRetryTask = nil
        gamepadRequestInFlight = false
        UserDefaults.standard.removeObject(forKey: savedDeviceIDKey)
        UserDefaults.standard.removeObject(forKey: savedDeviceNameKey)
        if voiceState != .idle { cancelVoice() }
        session = nil
        connectedDevice = nil
        activeDeviceID = nil
        needsPin = false
        pin = ""
        error = nil
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
        gamepadRequestInFlight = true
        let sid = UUID().uuidString
        status = "Запускаем канал пульта…"
        DebugLog.add("ЗАПРОС → getGamepadSession, sessionId=\(sid)")
        let requestID = cast.sendRequest(
            deviceId: id,
            request: LibSberCast.CastRequest(type: .getGamepadSessionCastRequest(sessionId: sid))
        )
        DebugLog.add("getGamepadSession request id: \(String(describing: requestID))")

        gamepadRetryTask?.cancel()
        gamepadRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await MainActor.run {
                guard self.gamepadRequestInFlight, self.session == nil else { return }
                self.gamepadRequestInFlight = false
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

    func onStatusChanged(status: LibSberCast.CastStatus) {
        DebugLog.add("ОТВЕТ SDK ← CastStatus: \(status.state)")
        switch status.state {
        case .stopped: self.status = hasSavedDevice ? "Телевизор сохранён" : "Остановлено"
        case .starting: self.status = "Запускаем обнаружение…"
        case .running: self.status = hasSavedDevice ? "Ищем сохранённый телевизор…" : "Ищем телевизор…"
        }
    }

    func onError(error: LibSberCast.CastError) {
        DebugLog.error("SberCast callback: \(error.msg)")
        if error.msg.contains("-72000") {
            // При уже полученной сессии discovery не перезапускаем: рабочий канал не трогаем.
            if connectedDevice != nil && session != nil { return }
            scheduleDiscoveryRestart()
            return
        }
        self.error = error.msg
        self.gamepadRequestInFlight = false
        self.status = hasSavedDevice ? "Ошибка подключения — телевизор сохранён" : "Ошибка подключения"
    }

    func onDevicesChanged(_ devices: [LibSberCast.SberCastDevice]) {
        DebugLog.add("ОТВЕТ SDK ← список устройств: \(devices.count) шт. [\(devices.map { $0.name }.joined(separator: ", "))]")
        self.devices = devices
        if !devices.isEmpty {
            discoveryRestarts = 0
            if error?.contains("локальной сети") == true { error = nil }
        }
        if devices.isEmpty {
            status = hasSavedDevice ? "Ищем сохранённый телевизор…" : "Телевизор не найден"
            return
        }
        if !autoConnectAttempted { reconnectSavedDeviceIfPossible() }
        if connectedDevice == nil && !hasSavedDevice { status = "Выберите телевизор" }
    }

    func onCastMessageResponse(message: LibSberCast.CastMessage) {
        DebugLog.add("ОТВЕТ SDK ← CastMessage: code=\(message.code), description=\(message.description)")
        if message.code != .success {
            DebugLog.error("CastMessage: \(message.description)")
            error = message.description
        }
    }

    func onCastRequestResponse(response: LibSberCast.CastRequestResponse) {
        DebugLog.add("ОТВЕТ SDK ← CastRequestResponse: code=\(response.code), type=\(response.type)")
        // PIN-ответ обрабатываем до общей проверки response.code:
        // SDK может вернуть конкретную причину отказа в status, даже если
        // верхнеуровневый код запроса не равен .success.
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
                cast.setAccessTokenForDevice(deviceId, accessToken: token)
                needsPin = false
                pin = ""
                error = nil
                gamepadRetryCount = 0
                requestGamepadSession()
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
            DebugLog.error("Cast request rejected: \(response.code)")
            error = "Запрос к телевизору отклонён (\(response.code))"
            status = connectedDevice == nil ? "Телевизор сохранён, но недоступен" : "Ошибка подключения"
            return
        }

        switch response.type {
        case .pinConnectCastResponse(let deviceId, let status):
            activeDeviceID = deviceId
            switch status {
            case .inputPinCode:
                needsPin = true
                error = nil
                self.status = "Введите код с телевизора"
            case .authorized, .sessionAlreadyActive:
                needsPin = false
                error = nil
                gamepadRetryCount = 0
                requestGamepadSession()
            default:
                error = "Телевизор отклонил подключение"
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
            gamepadRetryCount = 0
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

    func onBLEDeeplinkReceived(deeplink: String) {}
    func onBLEDeeplinkRunInfo(_ info: LibSberCast.RunBLEDeeplinkOnDeviceInfo) {}
}
