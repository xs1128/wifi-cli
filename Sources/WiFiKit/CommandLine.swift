import Darwin
import Foundation

public struct Command {
    public var request: Request?
    public var json = false
    public var passwordStdin = false
    public var timeout: TimeInterval = 45
    public var help = false

    public static let usage = """
    wifi — a small native macOS Wi-Fi CLI

    Usage:
      wifi status
      wifi scan
      wifi join SSID [--password-stdin | --open] [--dry-run]
      wifi disconnect [--dry-run]
      wifi power on|off [--dry-run]
      wifi permissions [--request]

    Options:
      --interface NAME   Choose a Wi-Fi interface; defaults to the system interface.
      --json             Emit one JSON response, including errors.
      --timeout SECONDS  Operation deadline, 1–120 seconds (default: 45).
      --dry-run          Validate a change without accessing Wi-Fi hardware.
      --                 Treat remaining arguments as literal positional values.

    join prompts securely on a terminal. --password-stdin reads one line (max 64
    bytes). Passwords are never accepted as command-line arguments or saved.
    Location permission is requested only by: wifi permissions --request
    """

    public static func parse(_ arguments: [String]) throws -> Command {
        var result = Command()
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
            result.help = true; return result
        }
        var positional: [String] = []
        var interface: String?
        var dryRun = false, open = false, requestPermission = false, literal = false
        var seen = Set<String>()
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            if literal { positional.append(arg); i += 1; continue }
            if arg == "--" { literal = true; i += 1; continue }
            if arg == "--help" || arg == "-h" { result.help = true; return result }
            if arg.hasPrefix("-") {
                guard seen.insert(arg).inserted else { throw Failure("arguments", "Duplicate option. See wifi --help.") }
                switch arg {
                case "--json": result.json = true
                case "--dry-run": dryRun = true
                case "--open": open = true
                case "--password-stdin": result.passwordStdin = true
                case "--request": requestPermission = true
                case "--interface", "--timeout":
                    i += 1
                    guard i < arguments.count else { throw Failure("arguments", "Missing value for \(arg).") }
                    if arg == "--interface" { interface = arguments[i] }
                    else {
                        guard let seconds = Double(arguments[i]), seconds.isFinite, (1...120).contains(seconds) else {
                            throw Failure("arguments", "Timeout must be between 1 and 120 seconds.")
                        }
                        result.timeout = seconds
                    }
                default: throw Failure("arguments", "Unknown option. See wifi --help.")
                }
            } else { positional.append(arg) }
            i += 1
        }
        guard let first = positional.first, let operation = Operation(rawValue: first) else {
            throw Failure("arguments", "Expected status, scan, join, disconnect, power, or permissions.")
        }
        var request = Request(operation)
        request.interface = interface
        request.dryRun = dryRun
        request.openNetwork = open
        request.requestPermission = requestPermission
        switch operation {
        case .join:
            guard positional.count == 2 else { throw Failure("arguments", "Usage: wifi join SSID [--password-stdin | --open]. Password arguments are not accepted.") }
            request.ssid = positional[1]
        case .power:
            guard positional.count == 2, ["on", "off"].contains(positional[1]) else {
                throw Failure("arguments", "Usage: wifi power on|off")
            }
            request.power = positional[1] == "on"
        default:
            guard positional.count == 1 else { throw Failure("arguments", "Unexpected positional arguments.") }
        }
        guard !result.passwordStdin || (operation == .join && !open && !dryRun) else {
            throw Failure("arguments", "--password-stdin requires a secured join without --dry-run.")
        }
        try request.validate(requirePassword: false)
        result.request = request
        return result
    }
}

public enum PasswordInput {
    public static func read(stdin: Bool) throws -> String {
        if !stdin {
            guard isatty(STDIN_FILENO) == 1 else {
                throw Failure("arguments", "No terminal is available. Supply --password-stdin or --open explicitly.")
            }
            // readpassphrase restores echo when interrupted; getpass does not reliably do so.
            var buffer = [CChar](repeating: 0, count: 66)
            defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
            guard readpassphrase("Wi-Fi password: ", &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
                throw Failure("arguments", "Password input was cancelled.")
            }
            return String(cString: buffer)
        }
        var bytes = [UInt8]()
        defer { bytes.withUnsafeMutableBytes { if let base = $0.baseAddress { _ = memset_s(base, $0.count, 0, $0.count) } } }
        while true {
            var byte: UInt8 = 0
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure("arguments", "Could not read password from stdin.")
            }
            if count == 0 || byte == 10 { break }
            guard bytes.count < 65 else { throw Failure("arguments", "Password exceeds 64 UTF-8 bytes.") }
            bytes.append(byte)
        }
        if bytes.last == 13 { bytes.removeLast() }
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw Failure("arguments", "Password input must be UTF-8.")
        }
        return text
    }
}
