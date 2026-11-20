import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var remote = SberCastRemote()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.black, Color(red: 0.08, green: 0.04, blue: 0.14), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if remote.connectedDevice != nil {
                RemotePadView(remote: remote)
            } else {
                ConnectionView(remote: remote)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: Binding(
            get: { remote.needsPin },
            set: { if !$0 && remote.needsPin { remote.cancelPin() } }
        )) {
            PinSheet(remote: remote)
        }
        .onAppear { remote.resume() }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                remote.resume()
            case .background:
                remote.pause()
            default:
                break
            }
        }
    }
}

struct ConnectionView: View {
    @ObservedObject var remote: SberCastRemote

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 12)
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(.white.opacity(0.08)).frame(width: 84, height: 84)
                    Image(systemName: "tv.fill").font(.system(size: 36, weight: .semibold))
                }
                Text("Salute Remote+")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Управление телевизором по Wi‑Fi")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
            }

            StatusCard(remote: remote)

            if !remote.devices.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Телевизоры")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.75))
                    ForEach(remote.devices, id: \.id) { device in
                        Button {
                            remote.connect(device)
                            Haptics.tap()
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "tv")
                                    .font(.title3)
                                    .frame(width: 42, height: 42)
                                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.name).font(.headline).foregroundStyle(.white)
                                    Text(device.features?.contains(.gamepadService) == true ? "Пульт доступен" : "Устройство найдено")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.35))
                            }
                            .padding(14)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
                        }
                        .buttonStyle(RemotePressStyle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 20)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

struct StatusCard: View {
    @ObservedObject var remote: SberCastRemote

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(remote.error == nil ? .green : .red).frame(width: 9, height: 9)
            Text(remote.error ?? remote.status)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(2)
            Spacer()
            if remote.devices.isEmpty {
                ProgressView().tint(.white)
            }
        }
        .padding(15)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct RemotePadView: View {
    @ObservedObject var remote: SberCastRemote
    @AppStorage("SaluteRemotePlus.touchpadMode") private var touchpadMode = false
    @State private var showKeyboard = false
    @State private var showDiagnostics = false

    private var channelColor: Color {
        if remote.session != nil && remote.wireReady { return .green }
        return remote.error == nil ? .orange : .red
    }

    private var channelText: String {
        if remote.session == nil { return "Подключение канала…" }
        return remote.wireReady ? "Пульт готов" : "Открываем канал…"
    }

    var body: some View {
        GeometryReader { proxy in
            let h = proxy.size.height
            let w = proxy.size.width
            let compact = h < 680
            let rowHeight = min(max(h * 0.080, 48), 62)
            let dpadBtn = min(max(min((w - 84) / 3.25, h * 0.092), 52), 70)
            let okBtn = min(dpadBtn + 6, 76)
            let dpadSpacing: CGFloat = compact ? 6 : 8
            let padHeight = dpadBtn * 2 + okBtn + dpadSpacing * 2 + (compact ? 22 : 30)

            VStack(spacing: compact ? 8 : 11) {
                // Верхняя панель устройства
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(remote.connectedDevice?.name ?? "Телевизор")
                            .font(.system(size: compact ? 20 : 22, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Circle().fill(channelColor).frame(width: 7, height: 7)
                            Text(channelText)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(channelColor)
                        }
                    }
                    Spacer()
                    Button {
                        Haptics.tap()
                        showDiagnostics = true
                    } label: {
                        Image(systemName: "stethoscope")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 38, height: 38)
                            .background(.white.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(RemotePressStyle())
                    .accessibilityLabel("Диагностика")

                    if remote.session == nil {
                        Button {
                            Haptics.tap()
                            remote.reconnectChannel()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 38, height: 38)
                                .background(.white.opacity(0.08), in: Circle())
                        }
                        .buttonStyle(RemotePressStyle())
                        .accessibilityLabel("Переподключить канал")
                    }

                    Button {
                        Haptics.tap()
                        remote.forgetSavedDevice()
                    } label: {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 38, height: 38)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(RemotePressStyle())
                    .accessibilityLabel("Сменить телевизор")
                }

                // Ряд 1: Питание (нажатие / удержание для меню), Настройки, Найти пульт
                HStack(spacing: 10) {
                    PowerRemoteButton(
                        height: rowHeight,
                        onDown: { remote.sendDown(.power) },
                        onUp: { remote.sendUp(.power) }
                    )
                    ActionRemoteButton(
                        symbol: "gearshape.fill",
                        title: "Настройки",
                        height: rowHeight
                    ) {
                        send(.settings)
                    }
                    ActionRemoteButton(
                        symbol: "dot.radiowaves.left.and.right",
                        title: "Найти пульт",
                        height: rowHeight
                    ) {
                        Haptics.tap()
                        remote.findRemote()
                    }
                }

                Spacer(minLength: 2)

                // Центр: Крестовина ИЛИ Сенсорная панель + кнопка переключения в сторонке
                ZStack {
                    RoundedRectangle(cornerRadius: 30)
                        .fill(.white.opacity(0.055))
                        .overlay(
                            RoundedRectangle(cornerRadius: 30)
                                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                        )

                    if touchpadMode {
                        TouchpadSurfaceView { command in
                            remote.send(command)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 30))
                    } else {
                        VStack(spacing: dpadSpacing) {
                            DPadCircleButton(symbol: "chevron.up", size: dpadBtn) { send(.up) }
                            HStack(spacing: dpadSpacing) {
                                DPadCircleButton(symbol: "chevron.left", size: dpadBtn) { send(.left) }
                                DPadCircleButton(title: "OK", size: okBtn, accent: true) { send(.ok) }
                                DPadCircleButton(symbol: "chevron.right", size: dpadBtn) { send(.right) }
                            }
                            DPadCircleButton(symbol: "chevron.down", size: dpadBtn) { send(.down) }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: padHeight)
                .overlay(alignment: .topTrailing) {
                    Button {
                        Haptics.medium()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            touchpadMode.toggle()
                        }
                    } label: {
                        Image(systemName: touchpadMode ? "circle.grid.cross.fill" : "hand.draw.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(touchpadMode ? Color.purple : Color.white.opacity(0.85))
                            .frame(width: 40, height: 40)
                            .background(
                                Circle()
                                    .fill(touchpadMode ? Color.purple.opacity(0.22) : Color.white.opacity(0.10))
                                    .overlay(
                                        Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(RemotePressStyle())
                    .padding(12)
                    .accessibilityLabel(touchpadMode ? "Переключить на крестовину" : "Переключить на сенсорную панель")
                }

                Spacer(minLength: 2)

                // Ряд 2: Назад, Домой
                HStack(spacing: 10) {
                    ActionRemoteButton(
                        symbol: "arrow.uturn.backward",
                        title: "Назад",
                        height: rowHeight
                    ) {
                        send(.back)
                    }
                    ActionRemoteButton(
                        symbol: "house.fill",
                        title: "Домой",
                        height: rowHeight
                    ) {
                        send(.home)
                    }
                }

                // Ряд 3: Громкость −, Mute, Громкость +
                HStack(spacing: 10) {
                    ActionRemoteButton(
                        symbol: "speaker.wave.1.fill",
                        title: "VOL −",
                        height: rowHeight
                    ) {
                        send(.volumeDown)
                    }
                    ActionRemoteButton(
                        symbol: "speaker.slash.fill",
                        title: "MUTE",
                        height: rowHeight
                    ) {
                        send(.mute)
                    }
                    ActionRemoteButton(
                        symbol: "speaker.wave.3.fill",
                        title: "VOL +",
                        height: rowHeight
                    ) {
                        send(.volumeUp)
                    }
                }

                // Ряд 4: Пауза/Плей, Голосовой поиск, Клавиатура
                HStack(spacing: 10) {
                    ActionRemoteButton(
                        symbol: "playpause.fill",
                        title: "Пауза / Плей",
                        height: rowHeight
                    ) {
                        send(.playPause)
                    }
                    ActionRemoteButton(
                        symbol: remote.voiceState == .idle ? "mic.fill" : "stop.fill",
                        title: remote.voiceState == .idle ? "Голос" : (remote.voiceState == .starting ? "Запуск…" : "Слушаю…"),
                        height: rowHeight,
                        highlighted: remote.voiceState != .idle
                    ) {
                        Haptics.tap()
                        remote.toggleVoice()
                    }
                    ActionRemoteButton(
                        symbol: "keyboard",
                        title: "Клавиатура",
                        height: rowHeight
                    ) {
                        Haptics.tap()
                        showKeyboard = true
                    }
                }

                // Компактная строка статуса / подсказки без прокрутки и сдвигов
                Text(footerText)
                    .font(.caption2)
                    .foregroundStyle(remote.error != nil ? Color.red.opacity(0.9) : Color.white.opacity(0.42))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(height: 16)
            }
            .padding(.horizontal, 16)
            .padding(.top, compact ? 6 : 10)
            .padding(.bottom, compact ? 6 : 10)
            .frame(width: w, height: h)
        }
        .sheet(isPresented: $showKeyboard) { TextInputSheet(remote: remote) }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsSheet(remote: remote, wire: remote.wire) }
    }

    private var footerText: String {
        if let error = remote.error { return error }
        if let notice = remote.notice { return notice }
        if touchpadMode { return "Свайпы · Тап = OK · Круг = Домой · < = Назад" }
        return "Удерживайте «Питание» для меню перезагрузки и выключения"
    }

    private func send(_ command: RemoteCommand) {
        Haptics.tap()
        remote.send(command)
    }
}

// MARK: - Кнопка питания с поддержкой удержания (меню перезагрузки/выключения ТВ)

struct PowerRemoteButton: View {
    let height: CGFloat
    let onDown: () -> Void
    let onUp: () -> Void

    @GestureState private var gesturePressed = false
    @State private var isPressed = false
    @State private var isHoldingMenu = false
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "power")
                .font(.system(size: height > 54 ? 19 : 17, weight: .bold))
            Text(isHoldingMenu ? "Меню ТВ…" : "Питание")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(isHoldingMenu ? .white : Color(red: 1.0, green: 0.44, blue: 0.44))
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    isHoldingMenu
                        ? Color.red.opacity(0.82)
                        : (isPressed ? Color.red.opacity(0.32) : Color.red.opacity(0.14))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.red.opacity(isHoldingMenu ? 0.95 : 0.30), lineWidth: 1)
        )
        .scaleEffect(isPressed ? 0.95 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isPressed)
        .animation(.easeOut(duration: 0.15), value: isHoldingMenu)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($gesturePressed) { _, state, _ in
                    state = true
                }
        )
        .onChange(of: gesturePressed) { active in
            if active {
                beginPress()
            } else {
                endPress()
            }
        }
        .onDisappear {
            endPress()
        }
        .accessibilityLabel("Питание. Короткое нажатие — включить или выключить. Удержание — меню перезагрузки и выключения.")
    }

    private func beginPress() {
        guard !isPressed else { return }
        isPressed = true
        isHoldingMenu = false
        Haptics.tap()
        onDown()

        holdTask?.cancel()
        holdTask = Task {
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard isPressed else { return }
                isHoldingMenu = true
                Haptics.heavy()
            }
        }
    }

    private func endPress() {
        holdTask?.cancel()
        holdTask = nil
        guard isPressed else { return }
        isPressed = false
        isHoldingMenu = false
        onUp()
    }
}

// MARK: - Сенсорная панель жестов

enum TouchpadGesture {
    case tapOK
    case swipeUp
    case swipeDown
    case swipeLeft
    case swipeRight
    case circleHome
    case chevronBack

    var command: RemoteCommand {
        switch self {
        case .tapOK: return .ok
        case .swipeUp: return .up
        case .swipeDown: return .down
        case .swipeLeft: return .left
        case .swipeRight: return .right
        case .circleHome: return .home
        case .chevronBack: return .back
        }
    }

    var symbol: String {
        switch self {
        case .tapOK: return "checkmark.circle.fill"
        case .swipeUp: return "chevron.up"
        case .swipeDown: return "chevron.down"
        case .swipeLeft: return "chevron.left"
        case .swipeRight: return "chevron.right"
        case .circleHome: return "house.fill"
        case .chevronBack: return "arrow.uturn.backward"
        }
    }

    var label: String {
        switch self {
        case .tapOK: return "OK"
        case .swipeUp: return "Вверх"
        case .swipeDown: return "Вниз"
        case .swipeLeft: return "Влево"
        case .swipeRight: return "Вправо"
        case .circleHome: return "Домой"
        case .chevronBack: return "Назад"
        }
    }
}

enum TouchpadGestureRecognizer {
    static func recognize(_ points: [CGPoint]) -> TouchpadGesture? {
        guard let start = points.first, let end = points.last else { return nil }

        let totalLength = pathLength(points)
        let chord = distance(start, end)

        // 1. Короткое нажатие (тап) → OK
        if totalLength < 20 && chord < 16 {
            return .tapOK
        }

        // 2. Круг (по часовой или против часовой) → Домой
        if isCircle(points, totalLength: totalLength, chord: chord) {
            return .circleHome
        }

        // 3. Жест «<» (верхний правый → левый центр → нижний правый) → Назад
        if isBackChevron(points, totalLength: totalLength) {
            return .chevronBack
        }

        // 4. Свайпы вверх / вниз / влево / вправо
        guard chord >= 26 else { return nil }
        let dx = end.x - start.x
        let dy = end.y - start.y
        if abs(dx) >= abs(dy) {
            return dx > 0 ? .swipeRight : .swipeLeft
        } else {
            return dy > 0 ? .swipeDown : .swipeUp
        }
    }

    private static func isCircle(_ points: [CGPoint], totalLength: CGFloat, chord: CGFloat) -> Bool {
        guard points.count >= 8, totalLength >= 100 else { return false }

        var minX = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var minY = CGFloat.infinity
        var maxY = -CGFloat.infinity
        for p in points {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }

        let bw = maxX - minX
        let bh = maxY - minY
        guard bw >= 36, bh >= 36 else { return false }
        let maxDim = max(bw, bh)
        let minDim = min(bw, bh)
        guard minDim / maxDim >= 0.42 else { return false }

        let center = CGPoint(x: (minX + maxX) * 0.5, y: (minY + maxY) * 0.5)
        var radii: [CGFloat] = []
        radii.reserveCapacity(points.count)
        var totalAngle: CGFloat = 0

        var prevVec: CGPoint?
        for p in points {
            let vx = p.x - center.x
            let vy = p.y - center.y
            let r = hypot(vx, vy)
            radii.append(r)
            guard r >= 6 else { continue }
            if let prev = prevVec {
                let cross = prev.x * vy - prev.y * vx
                let dot = prev.x * vx + prev.y * vy
                totalAngle += atan2(cross, dot)
            }
            prevVec = CGPoint(x: vx, y: vy)
        }

        let absAngle = abs(totalAngle)
        guard absAngle >= 4.2 else { return false }
        guard chord <= maxDim * 0.80 || absAngle >= 5.2 else { return false }

        let avgR = radii.reduce(0, +) / CGFloat(max(radii.count, 1))
        guard avgR >= 18 else { return false }
        let perimeterHits = radii.filter { $0 >= avgR * 0.30 }.count
        return Double(perimeterHits) / Double(radii.count) >= 0.72
    }

    private static func isBackChevron(_ points: [CGPoint], totalLength: CGFloat) -> Bool {
        guard points.count >= 3, totalLength >= 60,
              let start = points.first, let end = points.last else { return false }

        // Ищем самую левую точку (вершину стрелки «<»)
        var apexIndex = 0
        var minX = points[0].x
        for i in 1..<points.count {
            if points[i].x < minX {
                minX = points[i].x
                apexIndex = i
            }
        }

        guard apexIndex > 0, apexIndex < points.count - 1 else { return false }
        let apex = points[apexIndex]

        // Плечо 1: из верхнего правого угла влево и вниз к левому центру
        let dx1 = apex.x - start.x
        let dy1 = apex.y - start.y
        guard dx1 <= -24, dy1 >= 10 else { return false }

        // Плечо 2: из левого центра вправо и вниз к нижнему правому углу
        let dx2 = end.x - apex.x
        let dy2 = end.y - apex.y
        guard dx2 >= 24, dy2 >= 10 else { return false }

        // Конец заметно ниже начала (открытая справа стрелка «<», а не замкнутая фигура)
        guard (end.y - start.y) >= 32 else { return false }

        let leg1Len = pathLength(Array(points[0...apexIndex]))
        let leg2Len = pathLength(Array(points[apexIndex..<points.count]))
        let chord1 = hypot(dx1, dy1)
        let chord2 = hypot(dx2, dy2)
        guard leg1Len >= 26, leg2Len >= 26 else { return false }
        guard leg1Len / max(chord1, 1) <= 1.45, leg2Len / max(chord2, 1) <= 1.45 else { return false }

        return true
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return 0 }
        var sum: CGFloat = 0
        for i in 1..<points.count {
            sum += distance(points[i - 1], points[i])
        }
        return sum
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }
}

struct TouchpadSurfaceView: View {
    let onCommand: (RemoteCommand) -> Void

    @State private var trail: [CGPoint] = []
    @State private var feedback: TouchpadGesture?
    @State private var feedbackTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            // Тонкие подсказки направлений по краям сенсорной панели
            VStack {
                Image(systemName: "chevron.up")
                Spacer()
                HStack {
                    Image(systemName: "chevron.left")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                Spacer()
                Image(systemName: "chevron.down")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.18))
            .padding(16)

            // Центральная подсказка или вспышка распознанного жеста
            if let feedback {
                VStack(spacing: 6) {
                    Image(systemName: feedback.symbol)
                        .font(.system(size: 30, weight: .bold))
                    Text(feedback.label)
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.purple.opacity(0.65), in: RoundedRectangle(cornerRadius: 18))
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            } else if trail.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "hand.draw")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.26))
                    Text("Свайпы · Тап = OK")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.32))
                    Text("○ Домой   ·   < Назад")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.24))
                }
            }

            // След пальца при рисовании жеста
            if trail.count >= 2 {
                Path { path in
                    path.move(to: trail[0])
                    for point in trail.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(
                    LinearGradient(
                        colors: [Color.purple.opacity(0.35), Color.purple, Color.white.opacity(0.9)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if trail.isEmpty {
                        trail.append(value.startLocation)
                    }
                    if let last = trail.last, hypot(value.location.x - last.x, value.location.y - last.y) >= 3 {
                        trail.append(value.location)
                    }
                }
                .onEnded { value in
                    if trail.isEmpty {
                        trail = [value.startLocation, value.location]
                    } else {
                        trail.append(value.location)
                    }
                    let captured = trail
                    trail = []

                    if let gesture = TouchpadGestureRecognizer.recognize(captured) {
                        if gesture == .circleHome || gesture == .chevronBack {
                            Haptics.medium()
                        } else {
                            Haptics.tap()
                        }
                        onCommand(gesture.command)
                        showFeedback(gesture)
                    }
                }
        )
    }

    private func showFeedback(_ gesture: TouchpadGesture) {
        feedbackTask?.cancel()
        withAnimation(.easeOut(duration: 0.14)) {
            feedback = gesture
        }
        feedbackTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.18)) {
                    feedback = nil
                }
            }
        }
    }
}

// MARK: - Кнопки пульта

struct DPadCircleButton: View {
    var symbol: String?
    var title: String?
    let size: CGFloat
    var accent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                } else {
                    Text(title ?? "")
                }
            }
            .font(.system(size: title == nil ? 22 : 18, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(accent ? Color.purple.opacity(0.78) : Color.white.opacity(0.09))
            )
            .overlay(
                Circle()
                    .strokeBorder(.white.opacity(accent ? 0.25 : 0.08), lineWidth: 1)
            )
        }
        .buttonStyle(RemotePressStyle())
    }
}

struct ActionRemoteButton: View {
    let symbol: String
    let title: String
    let height: CGFloat
    var highlighted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: height > 54 ? 19 : 17, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(highlighted ? Color.purple.opacity(0.75) : Color.white.opacity(0.075))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.white.opacity(highlighted ? 0.28 : 0.08), lineWidth: 1)
            )
        }
        .buttonStyle(RemotePressStyle())
    }
}

struct RemotePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.84 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Ввод с клавиатуры

struct TextInputSheet: View {
    @ObservedObject var remote: SberCastRemote
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Ввод текста на ТВ").font(.headline).padding(.top, 20)
            Text("Сначала выберите поле ввода на ТВ (OK). Поддерживаются русский и английский.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
            TextField("Что набрать…", text: $text)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { send(submit: true) }
                .padding(14)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 10) {
                Button {
                    Haptics.tap()
                    remote.sendKey(KeyMap.backspace)
                } label: {
                    Label("Стереть", systemImage: "delete.left")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                Button {
                    Haptics.tap()
                    remote.sendKey(KeyMap.enter)
                } label: {
                    Label("Enter", systemImage: "return")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }
            Button { send(submit: true) } label: {
                Text("Набрать и нажать Enter")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(text.isEmpty)
            Button {
                remote.typeText(text, submit: false)
                Haptics.tap()
            } label: {
                Text("Только набрать")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .disabled(text.isEmpty)
            Button {
                remote.youtubeSearch(text)
                Haptics.tap()
                dismiss()
            } label: {
                Label("Искать на YouTube (любой язык)", systemImage: "play.rectangle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .disabled(text.isEmpty)
            if let notice = remote.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }

    private func send(submit: Bool) {
        guard !text.isEmpty else { return }
        Haptics.tap()
        remote.typeText(text, submit: submit)
        if remote.notice == nil {
            text = ""
            dismiss()
        }
    }
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func heavy() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
}

// MARK: - Ввод PIN-кода

struct PinSheet: View {
    @ObservedObject var remote: SberCastRemote
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield").font(.system(size: 40)).padding(.top, 28)
            Text("Код с экрана ТВ").font(.title2.bold())
            Text("Введите код, который показан на телевизоре \(remote.connectedDevice?.name ?? "")")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            TextField("0000", text: $remote.pin)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .focused($focused)
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .padding()
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            if let error = remote.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Button {
                remote.confirmPIN()
                Haptics.tap()
            } label: {
                Text("Подключить")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
            .buttonStyle(.borderedProminent)
            .disabled(remote.pin.isEmpty)
            Button("Отмена") { remote.cancelPin() }
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
        }
        .padding(.horizontal, 24)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }
}
