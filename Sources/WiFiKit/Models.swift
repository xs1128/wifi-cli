import Foundation

public enum Operation: String, Codable {
    case status, scan, join, disconnect, power, permissions
    public var changesConnection: Bool {
        self == .join || self == .disconnect || self == .power
    }
}

public struct Request: Codable {
    public var operation: Operation
    public var interface: String?
    public var ssid: String?
    public var password: String?
    public var openNetwork = false
    public var power: Bool?
    public var dryRun = false
    public var requestPermission = false

    public init(_ operation: Operation) { self.operation = operation }

    public func validate(requirePassword: Bool = true) throws {
        if let interface, interface.isEmpty || interface.utf8.count > 32 ||
            !interface.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) {
            throw Failure("arguments", "Invalid interface name.")
        }
        if operation == .join {
            guard let ssid, (1...32).contains(ssid.utf8.count), !ssid.utf8.contains(0) else {
                throw Failure("arguments", "SSID must contain 1–32 UTF-8 bytes and no NUL bytes.")
            }
            if openNetwork && password != nil {
                throw Failure("arguments", "An open-network request cannot include a password.")
            }
            if requirePassword && !dryRun && !openNetwork && password == nil {
                throw Failure("arguments", "Provide a password through the hidden prompt or --password-stdin; use --open for an open network.")
            }
            if let password, password.isEmpty || password.utf8.count > 64 || password.utf8.contains(0) {
                throw Failure("arguments", "Password must contain 1–64 UTF-8 bytes and no NUL bytes.")
            }
        } else if ssid != nil || password != nil || openNetwork {
            throw Failure("arguments", "Network credentials are only valid with join.")
        }
        if (operation == .power) != (power != nil) {
            throw Failure("arguments", "Power requests require on or off.")
        }
        if dryRun && !operation.changesConnection {
            throw Failure("arguments", "--dry-run is only valid for join, disconnect, and power.")
        }
        if requestPermission && operation != .permissions {
            throw Failure("arguments", "--request is only valid with permissions.")
        }
    }
}

public struct Failure: Error, Codable, Equatable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var exitCode: Int32 {
        switch code {
        case "arguments": return 2
        case "permission": return 3
        case "timeout": return 4
        case "authentication": return 5
        default: return 1
        }
    }
}

public struct WiFiStatus: Codable {
    public let interface: String
    public let poweredOn: Bool
    public let association: String
    public let ssid: String?
    public let bssid: String?
    public let rssiDBm: Int?
    public let noiseDBm: Int?
    public let transmitRateMbps: Double?
    public let channel: Int?
    public let band: String?
    public let addresses: [String]
    public let router: String?
    public let dnsServers: [String]

    public static func association(poweredOn: Bool, ssid: String?, phy: Int, mode: Int) -> String {
        if !poweredOn { return "poweredOff" }
        if ssid != nil || phy > 0 || mode == 1 { return "associated" }
        return mode == 0 ? "disconnected" : "unknown"
    }
}

public struct Network: Codable, Equatable {
    public let ssid: String?
    public let bssid: String?
    public let rssiDBm: Int
    public let channel: Int
    public let band: String
    public let security: String
}

public struct Response: Codable {
    public var ok: Bool
    public var operation: Operation?
    public var message: String?
    public var permission: String?
    public var status: WiFiStatus?
    public var networks: [Network]?
    public var warnings: [String] = []
    public var error: Failure?

    public init(operation: Operation, message: String? = nil) {
        ok = true; self.operation = operation; self.message = message
    }
    public init(error: Failure) { ok = false; self.error = error }
}

public protocol WiFiBackend {
    func status(interface: String?) throws -> WiFiStatus
    func scan(interface: String?) throws -> [Network]
    func join(interface: String?, ssid: String, password: String?, open: Bool) throws
    func disconnect(interface: String?) throws
    func setPower(interface: String?, on: Bool) throws
}

public enum Engine {
    public static func execute(_ request: Request, backend: WiFiBackend) throws -> Response {
        try request.validate()
        if request.dryRun {
            return Response(operation: request.operation, message: "Dry run: \(request.operation.rawValue) validated; no backend operation performed.")
        }
        var response = Response(operation: request.operation)
        switch request.operation {
        case .status:
            response.status = try backend.status(interface: request.interface)
        case .scan:
            response.networks = try backend.scan(interface: request.interface)
        case .join:
            try backend.join(interface: request.interface, ssid: request.ssid!, password: request.password, open: request.openNetwork)
            response.message = "Association completed. IP configuration and internet access have not been verified."
        case .disconnect:
            try backend.disconnect(interface: request.interface)
            response.message = "Disassociation requested. macOS may automatically rejoin a saved network."
        case .power:
            try backend.setPower(interface: request.interface, on: request.power!)
            response.message = "Wi-Fi power is \(request.power! ? "on" : "off")."
        case .permissions:
            throw Failure("protocol", "Permission requests must run in the helper application.")
        }
        return response
    }
}

public func terminalSafe(_ text: String) -> String {
    text.unicodeScalars.map { scalar in
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            return String(format: "\\u{%04X}", scalar.value)
        default: return String(scalar)
        }
    }.joined()
}
