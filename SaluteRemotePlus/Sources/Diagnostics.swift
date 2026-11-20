import SwiftUI
import UIKit

@MainActor
final class WireProbe: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var index = 0
    @Published private(set) var total = 0
    @Published private(set) var current: WireConfig?

    private var task: Task<Void, Never>?
    private var original: WireConfig?

    func start(wire: GamepadWire, session: GamepadSession) {
        guard !running else { return }
        let combinations = WireConfig.candidates(for: session)
        guard !combinations.isEmpty else {
            DebugLog.add("⚠️ Нет подходящих вариантов ключа")
            return
        }

        original = wire.config
        total = combinations.count
        running = true
        DebugLog.add("Автоподбор: \(combinations.count) вариантов")

        task = Task { [weak self] in
            for (offset, config) in combinations.enumerated() {
                guard let self, !Task.isCancelled else { return }
                self.index = offset + 1
                self.current = config
                DebugLog.add("[\(offset + 1)/\(combinations.count)] \(config.title)")

                let opened: Bool = await withCheckedContinuation { continuation in
                    wire.apply(config, persist: false) { continuation.resume(returning: $0) }
                }
                guard opened, !Task.isCancelled else {
                    if !Task.isCancelled { DebugLog.add("   ↳ канал не открылся, пропуск") }
                    continue
                }

                // Официальные коды Salute TV: Вправо = 23, Влево = 22.
                wire.press(Int32(RemoteCommand.right.buttonCode))
                try? await Task.sleep(nanoseconds: 750_000_000)
                wire.press(Int32(RemoteCommand.left.buttonCode))
                try? await Task.sleep(nanoseconds: 1_100_000_000)
            }

            guard let self, !Task.isCancelled else { return }
            self.finish(keep: false, wire: wire)
        }
    }

    func finish(keep: Bool, wire: GamepadWire? = nil) {
        task?.cancel()
        task = nil
        running = false

        if keep {
            wire?.commitCurrent()
            DebugLog.add("✅ Сохранён вариант: \(current?.title ?? "—")")
        } else if let original, let wire {
            wire.apply(original, persist: false)
        }
    }
}

struct DiagnosticsSheet: View {
    @ObservedObject var remote: SberCastRemote
    @ObservedObject var wire: GamepadWire
    @ObservedObject private var log = DebugLog.shared
    @StateObject private var probe = WireProbe()
    @State private var showSuccessAlert = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    card {
                        row("Сессия", remote.session == nil ? "нет" : "есть")
                        if let session = remote.session {
                            row("Порт", "\(session.port)")
                            row("Адреса", session.ipv4.joined(separator: ", "))
                            row("Версия сервиса", session.serviceVersion.isEmpty ? "—" : session.serviceVersion)
                            row("Ключ", GamepadWire.describeKey(session.aesKey))
                        }
                        row("Канал", wire.ready ? (wire.handshakeConfirmed ? "открыт (ТВ ответил)" : "открыт (ожидание ТВ)") : "закрыт")
                        row("Вариант", wire.config.title)
                    }

                    if let session = remote.session {
                        if probe.running {
                            Text("Вариант \(probe.index) из \(probe.total). Смотрите на фокус на экране ТВ: если курсор сдвинулся вправо/влево, нажмите «Работает».")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                            HStack {
                                Button("✅ Работает") { probe.finish(keep: true, wire: wire); showSuccessAlert = true }
                                    .buttonStyle(.borderedProminent)
                                Button("Остановить") { probe.finish(keep: false, wire: wire) }
                                    .buttonStyle(.bordered)
                            }
                        } else {
                            Button {
                                probe.start(wire: wire, session: session)
                            } label: {
                                Label("Автоподбор UDP-протокола (D-pad)", systemImage: "wand.and.stars")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)

                            HStack {
                                Button("Вправо →") { wire.press(Int32(RemoteCommand.right.buttonCode)) }.buttonStyle(.bordered)
                                Button("← Влево") { wire.press(Int32(RemoteCommand.left.buttonCode)) }.buttonStyle(.bordered)
                                Button("Переоткрыть") { wire.prepare(session: session) }.buttonStyle(.bordered)
                            }
                            .font(.footnote)

                            Button("Сбросить на базовый вариант") {
                                WireConfig.reset()
                                wire.apply(.baseline, persist: false)
                            }
                            .buttonStyle(.bordered)
                            .font(.footnote)

                            sberCastDirectTests
                            manualPickers
                            manualButtonTests
                        }
                    } else {
                        sberCastDirectTests
                        Button("Запросить канал заново") { remote.reconnectChannel() }
                            .buttonStyle(.borderedProminent)
                    }

                    HStack {
                        Text("Лог").font(.headline)
                        Spacer()
                        Button("Копировать") {
                            UIPasteboard.general.string = log.lines.joined(separator: "\n")
                        }
                        .font(.footnote)
                        Button("Очистить") { log.clear() }.font(.footnote)
                    }

                    Text(log.lines.suffix(60).joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(16)
            }
            .navigationTitle("Диагностика")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") {
                        probe.finish(keep: false, wire: wire)
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert("Найден рабочий вариант", isPresented: $showSuccessAlert) {
            Button("Отлично", role: .cancel) { }
        } message: {
            Text("Комбинация сохранена и будет использоваться основным пультом: \(probe.current?.title ?? wire.config.title)")
        }
    }

    private var manualButtonTests: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Проверка отдельных кнопок").font(.footnote).foregroundStyle(.white.opacity(0.5))
            Text("Команды отправляются через текущую конфигурацию канала. Проверяй реакцию телевизора после каждого нажатия.")
                .font(.caption2).foregroundStyle(.white.opacity(0.45))
            HStack {
                testButton("↑", code: Int32(RemoteCommand.up.buttonCode))
                testButton("←", code: Int32(RemoteCommand.left.buttonCode))
                testButton("OK", code: Int32(RemoteCommand.ok.buttonCode))
                testButton("→", code: Int32(RemoteCommand.right.buttonCode))
                testButton("↓", code: Int32(RemoteCommand.down.buttonCode))
            }
            HStack {
                testButton("Назад", code: Int32(RemoteCommand.back.buttonCode))
                testButton("Домой", code: Int32(RemoteCommand.home.buttonCode))
                Button("Настр.") { remote.send(.settings) }
                    .buttonStyle(.bordered)
                    .font(.caption)
                Button("Пит. 1.2с") { wire.longPress(Int32(RemoteCommand.power.buttonCode), duration: 1.2) }
                    .buttonStyle(.bordered)
                    .font(.caption)
            }
        }
        .padding(12)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func testButton(_ title: String, code: Int32) -> some View {
        Button(title) { wire.press(code) }
            .buttonStyle(.bordered)
            .font(.caption)
    }

    private var sberCastDirectTests: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Прямые команды SberCast (без UDP 6801)").font(.footnote).foregroundStyle(.white.opacity(0.5))
            HStack {
                Button("Громче") { remote.send(.volumeUp) }.buttonStyle(.bordered)
                Button("Тише") { remote.send(.volumeDown) }.buttonStyle(.bordered)
                Button("Mute") { remote.send(.mute) }.buttonStyle(.bordered)
                Button("Найти пульт") { remote.findRemote() }.buttonStyle(.bordered)
            }
            .font(.caption)
        }
        .padding(12)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private var manualPickers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ручной выбор").font(.footnote).foregroundStyle(.white.opacity(0.5))
            picker("Транспорт", WireConfig.Transport.allCases, \.transport) { $0.rawValue.uppercased() }
            picker("Шифр", WireConfig.CipherMode.allCases, \.cipher) { $0.title }
            picker("Формат", WireConfig.Framing.allCases, \.framing) { $0.title }
            picker("Ключ", WireConfig.KeyMode.allCases, \.keyMode) { $0.rawValue }
            picker("IV", WireConfig.IVMode.allCases, \.ivMode) { $0.title }
            picker("Данные", WireConfig.PayloadMode.allCases, \.payloadMode) { $0.title }
        }
    }

    private func picker<T: Hashable>(
        _ title: String,
        _ all: [T],
        _ keyPath: WritableKeyPath<WireConfig, T>,
        _ label: @escaping (T) -> String
    ) -> some View {
        HStack {
            Text(title).font(.footnote).frame(width: 80, alignment: .leading)
            Picker(title, selection: Binding(
                get: { wire.config[keyPath: keyPath] },
                set: { value in
                    var config = wire.config
                    config[keyPath: keyPath] = value
                    wire.apply(config)
                }
            )) {
                ForEach(all, id: \.self) { value in
                    Text(label(value)).tag(value)
                }
            }
            .pickerStyle(.menu)
            Spacer()
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).font(.footnote).foregroundStyle(.white.opacity(0.5))
                .frame(width: 110, alignment: .leading)
            Text(value).font(.footnote.monospaced())
        }
    }
}
