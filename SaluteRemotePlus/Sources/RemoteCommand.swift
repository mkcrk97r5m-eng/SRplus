import Foundation

enum RemoteCommand: String, CaseIterable, Identifiable {
    case power = "POWER"
    case mute = "MUTE"
    case up = "UP"
    case down = "DOWN"
    case left = "LEFT"
    case right = "RIGHT"
    case ok = "OK"
    case back = "BACK"
    case home = "HOME"
    case settings = "SETTINGS"
    case search = "SEARCH"
    case source = "SOURCE"
    case volumeUp = "VOLUME_UP"
    case volumeDown = "VOLUME_DOWN"
    case channelUp = "CHANNEL_UP"
    case channelDown = "CHANNEL_DOWN"
    case playPause = "PLAY_PAUSE"

    var id: String { rawValue }

    /// Официальные коды кнопок протокола Salute TV Gamepad (`Message.Gamepad.Button.code`).
    var buttonCode: UInt32 {
        switch self {
        case .up: return 20
        case .down: return 21
        case .left: return 22
        case .right: return 23
        case .ok: return 24
        case .back: return 34
        case .home: return 35
        case .volumeUp: return 37
        case .volumeDown: return 38
        case .power: return 39
        case .mute: return 40
        // Команды ниже преимущественно уходят через LibSberCast (deeplink / mediaCommand),
        // значения оставлены как безопасные резервные коды.
        case .settings: return 35
        case .search: return 84
        case .source: return 178
        case .channelUp: return 45
        case .channelDown: return 46
        case .playPause: return 24
        }
    }

    var keyCode: Int { Int(buttonCode) }
}

struct GamepadSession {
    let sessionId: String
    let port: UInt
    let serviceVersion: String
    let aesKey: String
    let ipv4: [String]
}

/// Linux input-event коды для `Message.Gamepad.KeyboardSignal` (как в официальном приложении Салют).
enum KeyMap {
    static let backspace: Int32 = 14   // KEY_BACKSPACE
    static let enter: Int32 = 28       // KEY_ENTER
}
