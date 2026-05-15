import Foundation

enum JSONSupport {
    static func data(_ value: Any) -> Data {
        let cleaned = sanitize(value)
        return (try? JSONSerialization.data(withJSONObject: cleaned, options: [])) ?? Data("{}".utf8)
    }

    static func string(_ value: Any) -> String {
        String(data: data(value), encoding: .utf8) ?? "{}"
    }

    static func parseObject(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        let value = try JSONSerialization.jsonObject(with: data, options: [])
        return value as? [String: Any] ?? [:]
    }

    static func sanitize(_ value: Any?) -> Any {
        guard let value else { return NSNull() }

        switch value {
        case let dict as [String: Any]:
            var output: [String: Any] = [:]
            for (key, item) in dict {
                output[key] = sanitize(item)
            }
            return output
        case let dict as [String: Any?]:
            var output: [String: Any] = [:]
            for (key, item) in dict {
                output[key] = sanitize(item)
            }
            return output
        case let array as [Any]:
            return array.map { sanitize($0) }
        case let number as NSNumber:
            return number
        case let string as String:
            return string
        case let bool as Bool:
            return bool
        case let int as Int:
            return int
        case let int64 as Int64:
            return int64
        case let double as Double:
            return double.isFinite ? double : 0
        case let float as Float:
            return float.isFinite ? float : 0
        default:
            return NSNull()
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func adding(_ key: String, _ value: Any?) -> [String: Any] {
        var copy = self
        if let value {
            copy[key] = value
        }
        return copy
    }
}

func shortLocalTime() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale.autoupdatingCurrent
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter.string(from: Date())
}

func millisecondsSince1970(_ date: Date = Date()) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
}

func makeUUID() -> String {
    UUID().uuidString.lowercased()
}
