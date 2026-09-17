import Foundation

/// Turns HTML's escapes back into the characters they stand for. Google's API returns the text a
/// comment is attached to with them still in ("(0&#8451;)"), which otherwise never matches the
/// notes and shows up in cards as it is.
nonisolated enum HTMLText {
    static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var rest = Substring(text)
        while let start = rest.firstIndex(of: "&") {
            result += rest[..<start]
            let body = rest[rest.index(after: start)...]
            // An entity is short and ends in a semicolon; a stray "&" is just an ampersand.
            guard let end = body.prefix(12).firstIndex(of: ";") else {
                result.append("&")
                rest = body
                continue
            }
            let name = String(body[..<end])
            if let character = character(for: name) {
                result.append(character)
            } else {
                result += "&\(name);"
            }
            rest = body[body.index(after: end)...]
        }
        return result + rest
    }

    private static func character(for name: String) -> Character? {
        if let named = named[name.lowercased()] { return named }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let value: UInt32? = if digits.hasPrefix("x") || digits.hasPrefix("X") {
            UInt32(digits.dropFirst(), radix: 16)
        } else {
            UInt32(digits)
        }
        return value.flatMap(Unicode.Scalar.init).map(Character.init)
    }

    private static let named: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "rsquo": "’", "lsquo": "‘", "ldquo": "“", "rdquo": "”", "mdash": "—", "ndash": "–",
        "hellip": "…", "deg": "°", "middot": "·", "bull": "•", "times": "×", "divide": "÷",
        "plusmn": "±", "frac12": "½", "frac14": "¼", "micro": "µ", "alpha": "α", "beta": "β",
        "gamma": "γ", "delta": "δ", "pi": "π", "mu": "μ", "sigma": "σ", "omega": "ω",
        "le": "≤", "ge": "≥", "ne": "≠", "asymp": "≈", "rarr": "→", "larr": "←", "harr": "↔",
        "copy": "©", "reg": "®", "trade": "™", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
    ]
}
