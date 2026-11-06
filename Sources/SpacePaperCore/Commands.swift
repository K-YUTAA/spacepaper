import Foundation
import Darwin

public struct RunningInstance: Codable, Equatable {
    public let id: String
    public let pid: Int32
    public init(id: String = UUID().uuidString, pid: Int32 = getpid()) { self.id = id; self.pid = pid }
}

public struct ControlCommand: Codable {
    public let id: String
    public let name: String
    public let path: String?
    // Optional only for decoding and rejecting requests left by version 1.0.
    public let issuedAt: Date?
    public let targetInstance: String?

    public init(id: String = UUID().uuidString, name: String, path: String? = nil,
                issuedAt: Date?, targetInstance: String?) {
        self.id = id; self.name = name; self.path = path
        self.issuedAt = issuedAt; self.targetInstance = targetInstance
    }
    public func isValid(for instance: String, now: Date) -> Bool {
        guard targetInstance == instance, let issuedAt = issuedAt else { return false }
        let age = now.timeIntervalSince(issuedAt)
        return age >= -2 && age < 15
    }
}

public struct CommandReply: Codable {
    public let id: String
    public let error: String?
}

public enum MailboxError: Error, LocalizedError {
    case notRunning, busy, io
    public var errorDescription: String? {
        switch self {
        case .notRunning: return "SpacePaperは起動していません。操作は保存していません。"
        case .busy: return "別の操作を処理中です。完了後に再実行してください。"
        case .io: return "SpacePaperの操作ファイルにアクセスできません。"
        }
    }
}

/// Every operation is serialized across processes. A request is consumed once,
/// and is valid only for the running instance to which the client addressed it.
public final class CommandMailbox {
    public let root: URL
    public var request: URL { root.appendingPathComponent("command.json") }
    public var instanceFile: URL { root.appendingPathComponent("instance.json") }
    private var replies: URL { root.appendingPathComponent("Replies", isDirectory: true) }
    public init(root: URL) { self.root = root }

    public func publish(_ instance: RunningInstance) throws {
        try locked {
            try JSONEncoder().encode(instance).write(to: instanceFile, options: .atomic)
            // A startup never executes a request addressed to an earlier process.
            if let data = try? Data(contentsOf: request) {
                let command = try? JSONDecoder().decode(ControlCommand.self, from: data)
                if command?.isValid(for: instance.id, now: Date()) != true { try FileManager.default.removeItem(at: request) }
            }
            for url in (try? FileManager.default.contentsOfDirectory(at: replies, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   Date().timeIntervalSince(date) > 60 { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    public func unpublish(_ instance: RunningInstance) {
        try? locked {
            if let current = try? JSONDecoder().decode(RunningInstance.self, from: Data(contentsOf: instanceFile)), current == instance {
                try FileManager.default.removeItem(at: instanceFile)
            }
        }
    }

    public func issue(_ name: String, path: String? = nil, now: Date = Date(),
                      isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) throws -> ControlCommand {
        try locked {
            guard let instance = try? JSONDecoder().decode(RunningInstance.self, from: Data(contentsOf: instanceFile)),
                  isAlive(instance.pid) else { throw MailboxError.notRunning }
            if let data = try? Data(contentsOf: request),
               let old = try? JSONDecoder().decode(ControlCommand.self, from: data), old.isValid(for: instance.id, now: now) {
                throw MailboxError.busy
            }
            let command = ControlCommand(name: name, path: path, issuedAt: now, targetInstance: instance.id)
            try JSONEncoder().encode(command).write(to: request, options: .atomic)
            return command
        }
    }

    public func take(for instance: RunningInstance, now: Date = Date()) throws -> ControlCommand? {
        try locked {
            guard FileManager.default.fileExists(atPath: request.path) else { return nil }
            let data = try Data(contentsOf: request)
            let command = try? JSONDecoder().decode(ControlCommand.self, from: data)
            try FileManager.default.removeItem(at: request)
            guard let command = command, command.isValid(for: instance.id, now: now) else { return nil }
            return command
        }
    }

    public func acknowledge(_ command: ControlCommand, error: String? = nil) throws {
        try locked {
            let reply = CommandReply(id: command.id, error: error)
            try JSONEncoder().encode(reply).write(to: replyURL(command.id), options: .atomic)
        }
    }

    public func reply(to command: ControlCommand) -> CommandReply? {
        try? JSONDecoder().decode(CommandReply.self, from: Data(contentsOf: replyURL(command.id)))
    }

    public func cancel(_ command: ControlCommand) throws {
        try locked {
            guard let data = try? Data(contentsOf: request),
                  let current = try? JSONDecoder().decode(ControlCommand.self, from: data), current.id == command.id else { return }
            try FileManager.default.removeItem(at: request)
        }
    }

    public func removeReply(to command: ControlCommand) { try? FileManager.default.removeItem(at: replyURL(command.id)) }
    private func replyURL(_ id: String) -> URL { replies.appendingPathComponent("\(id).json") }

    private func locked<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: replies, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent("control.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw MailboxError.io }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw MailboxError.io }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }
}

public enum UserPath {
    public static func absolute(_ input: String, directory: String = FileManager.default.currentDirectoryPath,
                                home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let expanded = input == "~" ? home : input.hasPrefix("~/") ? home + String(input.dropFirst()) : input
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(expanded)
        return url.standardizedFileURL.path
    }
}
