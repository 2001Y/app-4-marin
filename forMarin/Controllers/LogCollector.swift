import Foundation
import os.log
import OSLog
import UIKit

/// アプリ内ログを単一経路で収集し、共有用のテキストファイルを生成する。
@MainActor
final class LogCollector: ObservableObject {
    static let shared = LogCollector()

    private let logger = Logger(subsystem: "com.fourmarin.app", category: "LogCollector")

    private init() {}

    /// ログを集約したテキストファイルを生成する。
    func collectLogsAsFile() async -> URL? {
        await logCurrentDatabaseState()

        let timestamp = DateFormatter.logFilename.string(from: Date())
        let deviceName = sanitizedDeviceName()
        let filename = "4-Marin-\(deviceName)-\(timestamp).txt"
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        let content = await collectConsoleLogs()
        do {
            try content.write(to: destination, atomically: true, encoding: .utf8)
            logger.info("ログファイルを作成しました: \(destination.path)")
            return destination
        } catch {
            logger.error("ログファイル作成に失敗: \(error.localizedDescription)")
            return nil
        }
    }

    private func sanitizedDeviceName() -> String {
        let raw = UIDevice.current.name
        log("Raw device name: '\(raw)'", category: "LogCollector")
        let sanitized = raw
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{201C}", with: "")
            .replacingOccurrences(of: "\u{201D}", with: "")
            .replacingOccurrences(of: "の", with: "")
        log("Sanitized device name: '\(sanitized)'", category: "LogCollector")
        return sanitized
    }

    private func logCurrentDatabaseState() async {
        log("=== ログ収集開始前のDB状態確認 ===", category: "LogCollector")
        await MainActor.run {
            NotificationCenter.default.post(
                name: NSNotification.Name("RequestDatabaseDump"),
                object: nil,
                userInfo: ["source": "LogCollector"]
            )
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        log("=== DB状態確認完了 ===", category: "LogCollector")
    }

    private func collectConsoleLogs() async -> String {
        var output = generateHeader()
        output += "\n" + String(repeating: "=", count: 80) + "\n\n"
        output += "=== Captured Logs ===\n"
        output += collectAppLoggerEntries()
        return output
    }

    private func generateHeader() -> String {
        """
        4-Marin アプリログ
        生成日時: \(DateFormatter.fullDateTime.string(from: Date()))
        アプリバージョン: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "不明")
        """
    }

    private func collectAppLoggerEntries() -> String {
        let entries = AppLogger.shared.getAllLogs()
        guard !entries.isEmpty else {
            return "キャプチャされたログはありません。\nprint文をAppLogger.logに置き換えることでログがキャプチャされます。\n"
        }

        return entries.map { entry in
            "[\(DateFormatter.logTimestamp.string(from: entry.timestamp))] [\(entry.level)] [\(entry.category)] \(entry.message)"
        }.joined(separator: "\n") + "\n"
    }
}

// MARK: - AppLogger for Print Statement Capture

final class AppLogger {
    static let shared = AppLogger()

    private var logEntries: [LogEntry] = []
    private let maxEntries = 1000
    private let queue = DispatchQueue(label: "com.fourmarin.applogger", attributes: .concurrent)

    private init() {}

    struct LogEntry {
        let timestamp: Date
        let level: String
        let category: String
        let message: String
    }

    func log(_ message: String, level: String = "INFO", category: String = "App") {
        let entry = LogEntry(timestamp: Date(), level: level, category: category, message: message)
        queue.async(flags: .barrier) {
            self.logEntries.append(entry)
            if self.logEntries.count > self.maxEntries {
                self.logEntries.removeFirst(self.logEntries.count - self.maxEntries)
            }
        }
        oslog("[\(level)] [\(category)] \(message)", category: "AppLogger")
    }

    func getAllLogs() -> [LogEntry] {
        queue.sync { logEntries }
    }

    func clearLogs() {
        queue.async(flags: .barrier) {
            self.logEntries.removeAll()
        }
    }
}

// MARK: - Global Logging Helpers

func log(_ message: String, level: String = "INFO", category: String = "App") {
    AppLogger.shared.log(message, level: level, category: category)
}

func oslog(_ message: String, level: OSLogType = .info, category: String = "App") {
    let logger = Logger(subsystem: "com.fourmarin.app", category: category)
    switch level {
    case .debug:
        logger.debug("\(message)")
    case .info:
        logger.info("\(message)")
    case .error:
        logger.error("\(message)")
    case .fault:
        logger.fault("\(message)")
    default:
        logger.notice("\(message)")
    }
}

// MARK: - Helper Extensions

extension DateFormatter {
    static let logFilename: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static let fullDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .full
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter
    }()

    static let logTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}
