import AppKit
import CoreLocation
import Darwin
import Foundation
import WiFiKit

func emit(_ response: Response, json: Bool) {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(response) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
        return
    }
    if let error = response.error {
        FileHandle.standardError.write(Data("wifi: \(terminalSafe(error.message))\n".utf8))
        return
    }
    if let status = response.status {
        print("\(status.interface): \(status.poweredOn ? "on" : "off"), \(status.association)")
        print("Network: \(status.ssid.map(terminalSafe) ?? "unavailable")")
        if let bssid = status.bssid { print("BSSID: \(terminalSafe(bssid))") }
        if let rssi = status.rssiDBm { print("Signal: \(rssi) dBm; noise: \(status.noiseDBm ?? 0) dBm; TX: \(status.transmitRateMbps ?? 0) Mbps") }
        if let channel = status.channel { print("Channel: \(channel), \(status.band ?? "unknown")") }
        if !status.addresses.isEmpty { print("IP: \(status.addresses.joined(separator: ", "))") }
        if let router = status.router { print("Router: \(router)") }
        if !status.dnsServers.isEmpty { print("DNS: \(status.dnsServers.joined(separator: ", "))") }
    }
    if let networks = response.networks {
        print("SSID\tRSSI\tCHANNEL\tBAND\tSECURITY\tBSSID")
        for network in networks {
            print("\(network.ssid.map(terminalSafe) ?? "<hidden or unavailable>")\t\(network.rssiDBm)\t\(network.channel)\t\(network.band)\t\(network.security)\t\(network.bssid.map(terminalSafe) ?? "unavailable")")
        }
        print("\(networks.count) network results")
    }
    if let permission = response.permission { print("Location Services: \(permission)") }
    if let message = response.message { print(terminalSafe(message)) }
    for warning in response.warnings {
        FileHandle.standardError.write(Data("wifi: \(terminalSafe(warning))\n".utf8))
    }
}

func permissionName(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .authorizedAlways, .authorizedWhenInUse: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
}

final class HelperDelegate: NSObject, NSApplicationDelegate, CLLocationManagerDelegate {
    let channel: Channel
    let deadline: Deadline
    let clientPID: pid_t
    let location = CLLocationManager()
    var permissionPending = false
    var authorizationRequested = false
    var completed = false

    init(channel: Channel, deadline: Deadline, clientPID: pid_t) {
        self.channel = channel; self.deadline = deadline; self.clientPID = clientPID
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        location.delegate = self
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] _ in
            if deadline.remaining == 0 || kill(clientPID, 0) != 0 {
                Darwin.exit(4)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                try channel.authenticate(expectedPID: clientPID)
                let request = try channel.receive(Request.self)
                try request.validate()
                DispatchQueue.main.async { [self] in handle(request) }
            } catch { finish(Response(error: (error as? Failure) ?? Failure("transport", "Helper request failed."))) }
        }
    }

    func handle(_ request: Request) {
        if request.operation == .permissions {
            if request.requestPermission && location.authorizationStatus == .notDetermined {
                permissionPending = true
                // Core Location can suppress prompts from background applications.
                NSApp.setActivationPolicy(.regular)
                if #available(macOS 14.0, *) { NSApp.activate() }
                else { NSApp.activate(ignoringOtherApps: true) }
                requestLocationAuthorizationIfActive()
            } else {
                finishPermission(requested: request.requestPermission)
            }
            return
        }
        let permission = permissionName(location.authorizationStatus)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                var response = try Engine.execute(request, backend: NativeBackend())
                response.permission = permission
                if response.status?.association == "associated" && response.status?.ssid == nil {
                    response.warnings.append("The interface is associated, but its network identity is unavailable. Use wifi permissions --request to check access.")
                }
                if let networks = response.networks, networks.contains(where: { $0.ssid == nil || $0.bssid == nil }) {
                    response.warnings.append("Some scan identities are hidden or unavailable. Check Location Services with wifi permissions.")
                }
                finish(response)
            } catch { finish(Response(error: (error as? Failure) ?? Failure("backend", "Wi-Fi operation failed."))) }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        requestLocationAuthorizationIfActive()
    }

    func requestLocationAuthorizationIfActive() {
        guard permissionPending, !authorizationRequested, NSApp.isActive else { return }
        authorizationRequested = true
        location.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if permissionPending && manager.authorizationStatus != .notDetermined {
            permissionPending = false
            finishPermission(requested: true)
        }
    }

    func finishPermission(requested: Bool) {
        let name = permissionName(location.authorizationStatus)
        var response: Response
        if requested && name != "authorized" {
            response = Response(error: Failure("permission", "Location access is \(name). Enable WiFi CLI in System Settings → Privacy & Security → Location Services."))
        } else {
            response = Response(operation: .permissions)
            if name == "notDetermined" { response.message = "Run wifi permissions --request to ask macOS for access." }
        }
        response.permission = name
        finish(response)
    }

    func finish(_ response: Response) {
        // All completion state and app lifecycle changes stay on the main queue.
        DispatchQueue.main.async { [self] in
            guard !completed else { return }
            completed = true
            do { try channel.send(response) }
            catch { Darwin.exit(1) }
            Darwin.exit(0)
        }
    }
}

func runHelper(_ args: [String]) -> Never {
    let foreground = args.count == 7 && args[6] == "--permission-ui"
    guard (args.count == 6 || foreground), args[0] == "--helper", args[2] == "--client-pid",
          args[4] == "--deadline", let pid = Int32(args[3]), pid > 0,
          let end = Double(args[5]), end.isFinite else { Darwin.exit(2) }
    let deadline = Deadline(end: end)
    guard deadline.remaining > 0, deadline.remaining <= 121 else { Darwin.exit(2) }
    do {
        let channel = try Channel.connect(path: args[1], deadline: deadline)
        let app = NSApplication.shared
        app.setActivationPolicy(foreground ? .regular : .accessory)
        let delegate = HelperDelegate(channel: channel, deadline: deadline, clientPID: pid)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    } catch {}
    Darwin.exit(1)
}

final class CancellationCleanup {
    private let lock = NSLock()
    private var listener: Listener?
    private var sources: [DispatchSourceSignal] = []

    init() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if let listener = self.listener {
                    unlink(listener.path)
                    rmdir(listener.directory)
                }
                Darwin.exit(128 + number)
            }
            source.resume()
            sources.append(source)
        }
    }

    func makeListener() throws -> Listener {
        // Cancellation waits until creation completes, so it can remove both paths.
        lock.lock()
        defer { lock.unlock() }
        let created = try Listener()
        listener = created
        return created
    }

    deinit {
        for source in sources { source.cancel() }
        for number in [SIGINT, SIGTERM] { signal(number, SIG_DFL) }
    }
}

func callHelper(_ request: Request, deadline: Deadline) throws -> Response {
    guard let executable = Bundle.main.executableURL else { throw Failure("installation", "Cannot locate the CLI executable.") }
    let bundle = executable.resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard bundle.pathExtension == "app",
          FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("Contents/MacOS/WiFiHelper").path) else {
        throw Failure("installation", "Helper application is missing. Build with scripts/build.sh and run dist/bin/wifi.")
    }
    let cancellation = CancellationCleanup()
    defer { withExtendedLifetime(cancellation) {} }
    let listener = try cancellation.makeListener()
    let launcher = Process()
    launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    let foreground = request.operation == .permissions && request.requestPermission
    launcher.arguments = (foreground ? ["-n"] : ["-n", "-g"]) + [bundle.path, "--args", "--helper", listener.path,
                          "--client-pid", String(getpid()), "--deadline", String(deadline.end)] + (foreground ? ["--permission-ui"] : [])
    launcher.standardOutput = FileHandle.nullDevice
    launcher.standardError = FileHandle.nullDevice
    do { try launcher.run() }
    catch { throw Failure("installation", "Could not launch the helper application.") }
    let channel = try listener.accept(deadline: deadline)
    try channel.authenticate()
    try channel.send(request)
    return try channel.receive(Response.self)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--helper" { runHelper(arguments) }
let json = arguments.contains("--json")
do {
    let command = try Command.parse(arguments)
    if command.help { print(Command.usage); Darwin.exit(0) }
    guard geteuid() != 0 else { throw Failure("permission", "Run wifi as your logged-in user, without sudo.") }
    var request = command.request!
    if request.operation == .join && !request.openNetwork && !request.dryRun {
        request.password = try PasswordInput.read(stdin: command.passwordStdin)
    }
    defer { request.password = nil }
    try request.validate()
    let response: Response
    if request.dryRun {
        response = Response(operation: request.operation, message: "Dry run: \(request.operation.rawValue) validated; no backend operation performed.")
    } else {
        if request.operation == .permissions && request.requestPermission && !command.json {
            FileHandle.standardError.write(Data("Opening WiFi CLI for Location Services authorization. Respond to the macOS prompt.\n".utf8))
        }
        do { response = try callHelper(request, deadline: Deadline(seconds: command.timeout)) }
        catch let error as Failure where error.code == "timeout" && request.operation == .permissions && request.requestPermission {
            throw Failure("timeout", "No Location Services decision was received before the deadline. Check System Settings → Privacy & Security → Location Services for WiFi CLI, then run wifi permissions. Use --timeout 120 if you need more time to respond.")
        }
    }
    emit(response, json: command.json)
    Darwin.exit(response.error?.exitCode ?? (response.ok ? 0 : 1))
} catch {
    let failure = (error as? Failure) ?? Failure("internal", "The operation failed.")
    emit(Response(error: failure), json: json)
    Darwin.exit(failure.exitCode)
}
