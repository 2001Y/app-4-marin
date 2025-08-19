import Foundation
import os.log
import UIKit

/// 実際のコンソールログを収集してテキストファイルとして出力するクラス
@MainActor
class LogCollector: ObservableObject {
    static let shared = LogCollector()
    
    // アプリ専用のLogger
    private let logger = Logger(subsystem: "com.fourmarin.app", category: "LogCollector")
    
    private init() {}
    
    /// ログを収集してテキストファイルのURLを返す
    func collectLogsAsFile() async -> URL? {
        // ログ収集開始前に最新のDB状態を出力
        await logCurrentDatabaseState()
        
        let timestamp = DateFormatter.logFilename.string(from: Date())
        let deviceName = getDeviceName()
        let filename = "4-Marin-\(deviceName)-\(timestamp).txt"
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)
        
        let logContent = await collectConsoleLogs()
        
        do {
            try logContent.write(to: tempURL, atomically: true, encoding: .utf8)
            logger.info("ログファイルを作成しました: \(tempURL.path)")
            return tempURL
        } catch {
            logger.error("ログファイル作成に失敗: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// デバイス名を取得（ユーザーが設定したカスタム名）
    private func getDeviceName() -> String {
        let deviceName = UIDevice.current.name
        log("Raw device name: '\(deviceName)'", category: "LogCollector")
        
        // スペースをハイフンに置換し、特殊文字を除去してファイル名に適した形にする
        let sanitizedName = deviceName
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{201C}", with: "")
            .replacingOccurrences(of: "\u{201D}", with: "")
            .replacingOccurrences(of: "の", with: "")
        
        log("Sanitized device name: '\(sanitizedName)'", category: "LogCollector")
        return sanitizedName
    }
    
    /// ログ収集前に最新のDB状態をコンソールに出力
    private func logCurrentDatabaseState() async {
        log("=== ログ収集開始前のDB状態確認 ===", category: "LogCollector")
        
        // MessageStoreが利用可能な場合のみDB状態を出力
        await MainActor.run {
            // 現在アクティブなMessageStoreインスタンスを探す
            // これは理想的ではないが、グローバル状態にアクセスするための一時的な方法
            NotificationCenter.default.post(
                name: NSNotification.Name("RequestDatabaseDump"),
                object: nil,
                userInfo: ["source": "LogCollector"]
            )
        }
        
        // DB状態出力の完了を少し待つ
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒待機
        
        log("=== DB状態確認完了 ===", category: "LogCollector")
    }
    
    /// アプリ内ログを収集してテキストとして返す
    private func collectConsoleLogs() async -> String {
        var logContent = ""
        
        // ヘッダー情報
        logContent += generateHeader()
        logContent += "\n" + String(repeating: "=", count: 80) + "\n\n"
        
        // アプリ内キャプチャログのみ
        logContent += "アプリログ:\n"
        logContent += collectCapturedLogs()
        
        return logContent
    }
    
    private func generateHeader() -> String {
        return """
        4-Marin アプリログ
        生成日時: \(DateFormatter.fullDateTime.string(from: Date()))
        アプリバージョン: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "不明")
        """
    }
    
    /// アプリ内でキャプチャしたログを取得
    private func collectCapturedLogs() -> String {
        let capturedLogs = AppLogger.shared.getAllLogs()
        
        if capturedLogs.isEmpty {
            return "キャプチャされたログはありません。\nprint文をAppLogger.logに置き換えることでログがキャプチャされます。\n"
        }
        
        var logs = ""
        for logEntry in capturedLogs {
            logs += "[\(DateFormatter.logTimestamp.string(from: logEntry.timestamp))] [\(logEntry.level)] [\(logEntry.category)] \(logEntry.message)\n"
        }
        
        return logs
    }
}

// MARK: - AppLogger for Print Statement Capture

/// print文の代替として使用し、ログをキャプチャするクラス
class AppLogger {
    static let shared = AppLogger()
    
    private var logEntries: [LogEntry] = []
    private let maxEntries = 1000 // 最大保持ログ数
    private let queue = DispatchQueue(label: "com.fourmarin.applogger", attributes: .concurrent)
    
    private init() {}
    
    struct LogEntry {
        let timestamp: Date
        let level: String
        let category: String
        let message: String
    }
    
    /// ログを記録
    func log(_ message: String, level: String = "INFO", category: String = "App") {
        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            category: category,
            message: message
        )
        
        queue.async(flags: .barrier) {
            self.logEntries.append(entry)
            
            // 最大数を超えた場合は古いエントリを削除
            if self.logEntries.count > self.maxEntries {
                self.logEntries.removeFirst(self.logEntries.count - self.maxEntries)
            }
        }
        
        // 通常のprintも実行（Xcodeコンソールでも確認できるように）
        oslog("[\(level)] [\(category)] \(message)", category: "AppLogger")
    }
    
    /// 全てのログエントリを取得
    func getAllLogs() -> [LogEntry] {
        return queue.sync {
            return Array(logEntries)
        }
    }
    
    /// ログをクリア
    func clearLogs() {
        queue.async(flags: .barrier) {
            self.logEntries.removeAll()
        }
    }
}

// MARK: - Global Logging Functions

/// 既存のprint文を簡単に置き換えるためのグローバル関数
func log(_ message: String, level: String = "INFO", category: String = "App") {
    AppLogger.shared.log(message, level: level, category: category)
}

/// OSLoggerを使用したシステムレベルのログ記録
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