import Darwin
import Foundation

enum LocalNetworkAddress {
    static func currentIPv4() -> String {
        guard let interfaces = ipv4Interfaces(), !interfaces.isEmpty else {
            return "127.0.0.1"
        }

        return interfaces.sorted { lhs, rhs in
            score(lhs.name) < score(rhs.name)
        }.first?.address ?? "127.0.0.1"
    }

    private static func ipv4Interfaces() -> [(name: String, address: String)]? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        var result: [(name: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }

            let interface = current.pointee
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else {
                continue
            }

            let name = String(cString: interface.ifa_name)
            guard !name.hasPrefix("awdl"), !name.hasPrefix("llw") else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0 else { continue }

            let ip = host.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!)
            }
            guard !ip.hasPrefix("169.254.") else { continue }
            result.append((name: name, address: ip))
        }
        return result
    }

    private static func score(_ name: String) -> Int {
        if name == "en0" { return 0 }
        if name == "en1" { return 1 }
        if name.hasPrefix("en") { return 2 }
        if name.hasPrefix("bridge") { return 4 }
        if name.hasPrefix("utun") { return 5 }
        return 3
    }
}
