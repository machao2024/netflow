import Foundation
import Darwin
import SystemConfiguration

public struct NetworkInterface: Identifiable, Equatable {
    public let name: String
    public let label: String
    public var id: String { name }
}

public enum NetworkReader {
    private static let dynamicStore = SCDynamicStoreCreate(nil, "NetFlow" as CFString, nil, nil)

    private static func linkIsActive(_ name: String, flags: Int32) -> Bool {
        if let store = dynamicStore,
           let state = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(name)/Link" as CFString) as? [String: Any],
           let active = state["Active"] as? Bool {
            return active
        }
        return flags & IFF_UP != 0 && flags & IFF_RUNNING != 0
    }
    public static func interfaces() -> [NetworkInterface] {
        guard let list = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        var seen = Set<String>()
        return list.compactMap { item -> NetworkInterface? in
            guard let name = SCNetworkInterfaceGetBSDName(item) as String?, seen.insert(name).inserted else { return nil }
            let title = SCNetworkInterfaceGetLocalizedDisplayName(item) as String? ?? name
            return NetworkInterface(name: name, label: "\(title) · \(name)")
        }.sorted { $0.name < $1.name }
    }

    /// NET_RT_IFLIST2 supplies 64-bit byte counters (getifaddrs may expose 32-bit counters).
    public static func read(interface: String = "auto") throws -> CounterSnapshot {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        // The interface list may change between the two sysctl calls. Retry ENOMEM.
        for attempt in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var data = [UInt8](repeating: 0, count: size)
            let status = data.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
            if status != 0 {
                if errno == ENOMEM && attempt < 2 { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var counters: [InterfaceCounter] = []
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset + 4 <= size {
                    let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                    guard length >= 4, offset + length <= size else { break }
                    if raw[offset + 3] == UInt8(RTM_IFINFO2), length >= MemoryLayout<if_msghdr2>.size {
                        let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                        var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                        if if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil {
                            let name = String(cString: nameBuffer)
                            // macOS Ethernet, Wi-Fi, USB tethering use en*. Never add utun/awdl/lo0
                            // to the same total, which would count the same packets twice.
                            let selected = interface == "auto" ? isPhysicalName(name) : name == interface
                            if selected {
                                counters.append(InterfaceCounter(name: name, index: UInt32(message.ifm_index),
                                    received: message.ifm_data.ifi_ibytes, sent: message.ifm_data.ifi_obytes,
                                    isUp: linkIsActive(name, flags: message.ifm_flags)))
                            }
                        }
                    }
                    offset += length
                }
            }
            return CounterSnapshot(date: Date(), uptime: ProcessInfo.processInfo.systemUptime, interfaces: counters)
        }
        throw POSIXError(.EIO)
    }

    public static func isPhysicalName(_ name: String) -> Bool {
        guard name.hasPrefix("en") else { return false }
        let suffix = name.dropFirst(2)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }
}
