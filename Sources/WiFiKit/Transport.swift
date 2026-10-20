import Darwin
import Foundation
import Security

public struct Deadline {
    public let end: TimeInterval
    public init(seconds: TimeInterval) { end = ProcessInfo.processInfo.systemUptime + seconds }
    public init(end: TimeInterval) { self.end = end }
    public var remaining: TimeInterval { max(0, end - ProcessInfo.processInfo.systemUptime) }
    public func check() throws {
        guard remaining > 0 else {
            throw Failure("timeout", "Deadline exceeded. A change may still complete; run status before retrying.")
        }
    }
}

private func waitFor(_ fd: Int32, events: Int16, deadline: Deadline) throws {
    while true {
        try deadline.check()
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let milliseconds = Int32(min(1000, max(1, deadline.remaining * 1000)))
        let result = poll(&descriptor, 1, milliseconds)
        if result < 0 {
            if errno == EINTR { continue }
            throw Failure("transport", "Local IPC polling failed.")
        }
        if result > 0 {
            if descriptor.revents & events != 0 { return }
            throw Failure("transport", "The local helper connection closed.")
        }
    }
}

private func configure(_ fd: Int32) throws {
    var one: Int32 = 1
    guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
          fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0,
          setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else {
        throw Failure("transport", "Could not configure local IPC.")
    }
}

private func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
    var address = sockaddr_un()
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw Failure("transport", "Local socket path is too long.")
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return try withUnsafePointer(to: &address) {
        try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

public final class Channel {
    public static let maxFrame = 1_048_576
    public let fd: Int32
    public let deadline: Deadline
    public init(fd: Int32, deadline: Deadline) throws {
        self.fd = fd; self.deadline = deadline
        do { try configure(fd) } catch { Darwin.close(fd); throw error }
    }
    deinit { Darwin.close(fd) }

    public func send<T: Encodable>(_ value: T) throws {
        var payload = try JSONEncoder().encode(value)
        defer { payload.resetBytes(in: 0..<payload.count) }
        guard payload.count > 0, payload.count <= Self.maxFrame else {
            throw Failure("protocol", "Local response exceeds the message limit.")
        }
        var size = UInt32(payload.count).bigEndian
        try withUnsafeBytes(of: &size) { try write(Data($0)) }
        try write(payload)
    }

    public func receive<T: Decodable>(_ type: T.Type) throws -> T {
        let prefix = try read(count: 4)
        let count = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= Self.maxFrame else { throw Failure("protocol", "Invalid local message length.") }
        var payload = try read(count: count)
        defer { payload.resetBytes(in: 0..<payload.count) }
        do { return try JSONDecoder().decode(type, from: payload) }
        catch { throw Failure("protocol", "Malformed local message.") }
    }

    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try waitFor(fd, events: Int16(POLLOUT), deadline: deadline)
                let sent = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if sent < 0 && [EINTR, EAGAIN].contains(errno) { continue }
                guard sent > 0 else { throw Failure("transport", "Could not write to the local helper.") }
                offset += sent
            }
        }
    }

    private func read(count: Int) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                try waitFor(fd, events: Int16(POLLIN), deadline: deadline)
                let received = recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
                if received < 0 && [EINTR, EAGAIN].contains(errno) { continue }
                guard received > 0 else { throw Failure("transport", "The local helper connection closed.") }
                offset += received
            }
        }
        return result
    }

    public func authenticate(expectedPID: pid_t? = nil) throws {
        var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
              expectedPID == nil || expectedPID == pid else {
            throw Failure("transport", "Local peer identity did not match.")
        }
        var ownCode: SecCode?, peerCode: SecCode?, ownStaticCode: SecStaticCode?, requirement: SecRequirement?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess,
              let ownCode,
              SecCodeCopyStaticCode(ownCode, [], &ownStaticCode) == errSecSuccess,
              let ownStaticCode,
              SecCodeCopyDesignatedRequirement(ownStaticCode, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &peerCode) == errSecSuccess,
              let peerCode,
              SecCodeCheckValidity(peerCode, [], requirement) == errSecSuccess else {
            throw Failure("transport", "Local peer signature did not match. Rebuild both CLI and helper with scripts/build.sh.")
        }
    }

    public static func connect(path: String, deadline: Deadline) throws -> Channel {
        var directory = stat(), socketInfo = stat()
        guard lstat(URL(fileURLWithPath: path).deletingLastPathComponent().path, &directory) == 0,
              directory.st_uid == geteuid(), directory.st_mode & 0o777 == 0o700,
              directory.st_mode & S_IFMT == S_IFDIR,
              lstat(path, &socketInfo) == 0, socketInfo.st_uid == geteuid(),
              socketInfo.st_mode & S_IFMT == S_IFSOCK, socketInfo.st_mode & 0o777 == 0o600 else {
            throw Failure("transport", "Local socket ownership or permissions are invalid.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("transport", "Could not create local IPC.") }
        let connected: Int32
        do { connected = try withAddress(path) { Darwin.connect(fd, $0, $1) } }
        catch { Darwin.close(fd); throw error }
        guard connected == 0 else { Darwin.close(fd); throw Failure("transport", "Could not connect to the CLI.") }
        return try Channel(fd: fd, deadline: deadline)
    }
}

public final class Listener {
    public let directory: String
    public let path: String
    private let fd: Int32
    public init() throws {
        var template = Array("/private/tmp/wifi-cli.XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw Failure("transport", "Could not create private IPC directory.") }
        directory = String(cString: created)
        path = directory + "/ipc"
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        do {
            guard fd >= 0 else { throw Failure("transport", "Could not create local IPC.") }
            try configure(fd)
            guard try withAddress(path, { bind(fd, $0, $1) }) == 0,
                  chmod(path, 0o600) == 0, listen(fd, 1) == 0 else {
                throw Failure("transport", "Could not start local IPC.")
            }
        } catch {
            Darwin.close(fd); unlink(path); rmdir(directory); throw error
        }
    }
    deinit { Darwin.close(fd); unlink(path); rmdir(directory) }
    public func accept(deadline: Deadline) throws -> Channel {
        while true {
            try waitFor(fd, events: Int16(POLLIN), deadline: deadline)
            let peer = Darwin.accept(fd, nil, nil)
            if peer < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard peer >= 0 else { throw Failure("transport", "Could not accept helper IPC.") }
            return try Channel(fd: peer, deadline: deadline)
        }
    }
}
