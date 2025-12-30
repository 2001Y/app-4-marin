import Foundation
import os.log
import OSLog
import UIKit

/// ## Role / Responsibility
/// - アプリ内ログを一箇所に集約し、共有/解析しやすい形式へ出力する。
/// - `AppLogger` はメモリ上のリングバッファに加えて、（Simulatorでは）ファイルにも追記して
///   実行後に外部からログを回収できるようにする。
///
/// NOTE:
/// - 端末側では永続ログの取り扱い（容量/プライバシー）に注意が必要なため、ファイル追記は Simulator 限定。

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
#if DEBUG
    /// Debug環境での「確実なログ回収」用。unified logging が取りづらい/時刻やpredicateで取りこぼすケースがあるため、
    /// 最低限のログをファイルにも追記して後から回収できるようにする。
    /// 実機でも有効（Debugビルド限定）。
    private let fileQueue = DispatchQueue(label: "com.fourmarin.applogger.file", qos: .utility)
    private lazy var fileURL: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent("applogger.log")
    }()
#endif

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

#if DEBUG
        // Debug環境ではファイルにも追記して、テスト後に回収できるようにする。
        // 実機: devicectl device copy from で回収
        // Simulator: simctl get_app_container で回収
        if let fileURL {
            let line = "[\(DateFormatter.logTimestamp.string(from: entry.timestamp))] [\(entry.level)] [\(entry.category)] \(entry.message)\n"
            fileQueue.async {
                do {
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        let handle = try FileHandle(forWritingTo: fileURL)
                        try handle.seekToEnd()
                        if let data = line.data(using: .utf8) {
                            try handle.write(contentsOf: data)
                        }
                        try handle.close()
                    } else {
                        try line.write(to: fileURL, atomically: true, encoding: .utf8)
                    }
                } catch {
                    // ログ回収用の補助経路なので、失敗してもアプリ動作に影響を出さない
                }
            }
        }
#endif
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

// #region agent log
/// Cursor DEBUG MODE用: 端末実行中の状態を Mac 側の NDJSON ingest に送るための最小ロガー。
/// - NOTE: PII/秘密情報は送らないこと（IDはprefix等に丸める）
enum AgentNDJSONLogger {
    private static let endpoint = URL(string: "http://127.0.0.1:7242/ingest/7496e73d-4eec-4b5f-8a58-b80af467f32f")!

    static func post(sessionId: String = "debug-session",
                     runId: String,
                     hypothesisId: String,
                     location: String,
                     message: String,
                     data: [String: Any] = [:]) {
        let payload: [String: Any] = [
            "sessionId": sessionId,
            "runId": runId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        // ローカル端末（実機）では 127.0.0.1 の ingest に到達できないため、
        // AppLogger にも同じ情報を出してユーザーが「ログを共有」から提出できるようにする。
        // NOTE: data は呼び出し側で prefix などに丸め、PII/秘密情報を入れない。
        let dataSummary = data.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
        AppLogger.shared.log("[AGENT_NDJSON] runId=\(runId) hypo=\(hypothesisId) loc=\(location) msg=\(message) data={\(dataSummary)}",
                             level: "DEBUG",
                             category: "AgentNDJSON")
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }
}
// #endregion

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
