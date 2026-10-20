import CoreWLAN
import Foundation
import SystemConfiguration

public final class NativeBackend: WiFiBackend {
    private let client = CWWiFiClient.shared()
    public init() {}

    private func interface(_ name: String?) throws -> CWInterface {
        guard let iface = name.map({ client.interface(withName: $0) }) ?? client.interface() else {
            throw Failure("interface", "No Wi-Fi interface is available.")
        }
        return iface
    }

    private func poweredInterface(_ name: String?) throws -> CWInterface {
        let iface = try interface(name)
        guard iface.powerOn() else { throw Failure("power", "Wi-Fi is powered off.") }
        return iface
    }

    public func status(interface name: String?) throws -> WiFiStatus {
        let iface = try interface(name)
        let powered = iface.powerOn()
        let ssid = iface.ssid()
        let association = WiFiStatus.association(
            poweredOn: powered, ssid: ssid,
            phy: iface.activePHYMode().rawValue, mode: iface.interfaceMode().rawValue
        )
        let linked = association == "associated"
        let channel = linked ? iface.wlanChannel() : nil
        let name = iface.interfaceName ?? "unknown"
        let ip = IPConfiguration.read(interface: name)
        return WiFiStatus(
            interface: name, poweredOn: powered, association: association,
            ssid: ssid, bssid: iface.bssid(),
            rssiDBm: linked ? iface.rssiValue() : nil,
            noiseDBm: linked ? iface.noiseMeasurement() : nil,
            transmitRateMbps: linked ? iface.transmitRate() : nil,
            channel: channel?.channelNumber,
            band: channel.map { Self.band($0.channelBand) },
            addresses: ip.addresses, router: ip.router, dnsServers: ip.dns
        )
    }

    public func scan(interface name: String?) throws -> [Network] {
        let iface = try poweredInterface(name)
        do {
            return try iface.scanForNetworks(withSSID: nil).map {
                Network(ssid: $0.ssid, bssid: $0.bssid, rssiDBm: $0.rssiValue,
                        channel: $0.wlanChannel?.channelNumber ?? 0,
                        band: $0.wlanChannel.map { Self.band($0.channelBand) } ?? "unknown",
                        security: Self.security($0))
            }.sorted {
                if $0.rssiDBm != $1.rssiDBm { return $0.rssiDBm > $1.rssiDBm }
                return ($0.ssid ?? "", $0.bssid ?? "", $0.channel) < ($1.ssid ?? "", $1.bssid ?? "", $1.channel)
            }
        } catch { throw Self.failure(error) }
    }

    public func join(interface name: String?, ssid: String, password: String?, open: Bool) throws {
        let iface = try poweredInterface(name)
        // Association is not an internet check. Never retry it or toggle power as a fallback.
        do {
            let data = Data(ssid.utf8)
            let scanned = try iface.scanForNetworks(withSSID: data)
            let matches = scanned.filter { $0.ssidData == data || $0.ssid == ssid }
            guard let network = matches.sorted(by: { $0.rssiValue > $1.rssiValue }).first else {
                if scanned.contains(where: { $0.ssid == nil }) {
                    throw Failure("permission", "Scan identities are unavailable. Grant Location Services with wifi permissions --request, then retry.")
                }
                throw Failure("notFound", "The requested network was not found. No association was attempted.")
            }
            if open {
                guard network.supportsSecurity(.none) else {
                    throw Failure("authentication", "The selected network is secured; --open is not applicable.")
                }
            } else {
                guard [.wpa2Personal, .wpa3Personal, .wpa3Transition].contains(where: { network.supportsSecurity($0) }) else {
                    throw Failure("authentication", "Secured joins support WPA2/WPA3 Personal. Use an installed configuration profile for enterprise Wi-Fi.")
                }
            }
            try iface.associate(to: network, password: password)
        } catch { throw Self.failure(error) }
    }

    public func disconnect(interface name: String?) throws {
        try poweredInterface(name).disassociate()
    }

    public func setPower(interface name: String?, on: Bool) throws {
        let iface = try interface(name)
        if iface.powerOn() == on { return }
        do { try iface.setPower(on) }
        catch { throw Self.failure(error) }
    }

    private static func band(_ band: CWChannelBand) -> String {
        switch band.rawValue {
        case 1: return "2.4 GHz"
        case 2: return "5 GHz"
        case 3: return "6 GHz"
        default: return "unknown"
        }
    }

    private static func security(_ network: CWNetwork) -> String {
        let labels: [(CWSecurity, String)] = [
            (.wpa3Transition, "WPA2/WPA3 Personal"), (.wpa3Personal, "WPA3 Personal"),
            (.wpa3Enterprise, "WPA3 Enterprise"), (.wpa2Enterprise, "WPA2 Enterprise"),
            (.wpa2Personal, "WPA2 Personal"), (.wpaEnterprise, "WPA Enterprise"),
            (.wpaPersonal, "WPA Personal"), (.WEP, "WEP"), (.none, "Open"),
        ]
        return labels.first { network.supportsSecurity($0.0) }?.1 ?? "Unknown"
    }

    private static func failure(_ error: Error) -> Failure {
        if let error = error as? Failure { return error }
        let error = error as NSError
        // Driver descriptions can contain inputs. Return only controlled text and numeric codes.
        switch error.code {
        case -3903, -3906:
            return Failure("authentication", "Wi-Fi authentication failed (\(error.code)).")
        case -3908, -3925:
            return Failure("timeout", "Wi-Fi operation timed out. It may still complete; check status before retrying.")
        case -3930:
            return Failure("permission", "macOS denied the Wi-Fi operation. Check system policy and Location Services.")
        default:
            return Failure("backend", "CoreWLAN operation failed (\(error.code)). No fallback or retry was attempted.")
        }
    }
}

private enum IPConfiguration {
    static func read(interface: String) -> (addresses: [String], router: String?, dns: [String]) {
        guard let store = SCDynamicStoreCreate(nil, "wifi-cli" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv[46]" as CFString) as? [String] else {
            return ([], nil, [])
        }
        var addresses = Set<String>(), dns = Set<String>()
        var router: String?
        for key in keys.sorted() {
            guard let state = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  state["InterfaceName"] as? String == interface else { continue }
            addresses.formUnion(state["Addresses"] as? [String] ?? [])
            if router == nil { router = state["Router"] as? String }
            let dnsKey = key.components(separatedBy: "/").dropLast().joined(separator: "/") + "/DNS"
            if let state = SCDynamicStoreCopyValue(store, dnsKey as CFString) as? [String: Any] {
                dns.formUnion(state["ServerAddresses"] as? [String] ?? [])
            }
        }
        return (addresses.sorted(), router, dns.sorted())
    }
}
