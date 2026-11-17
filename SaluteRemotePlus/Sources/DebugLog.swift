import Foundation
import Combine

/// Лог диагностики: храним последние 150 строк.
final class DebugLog: ObservableObject {
    static let shared = DebugLog()
    @Published private(set) var lines: [String] = []

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func add(_ text: String) {
        DispatchQueue.main.async { shared.append(text) }
    }

    static func error(_ text: String) {
        add("❌ ОШИБКА: \(text)")
    }

    private func append(_ text: String) {
        lines.append("\(formatter.string(from: Date())) \(text)")
        if lines.count > 150 { lines.removeFirst(lines.count - 150) }
    }

    func clear() { lines.removeAll() }
}
