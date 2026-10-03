import Foundation

/// Normalize line endings only after a caller has chosen to interpret command
/// output as text. Transport Data, hashes, downloads and binary payloads stay raw.
enum CommandText {
    static func normalize(_ text: String) -> String {
        var result = String.UnicodeScalarView(), carriageReturns = 0
        for scalar in text.unicodeScalars {
            if scalar.value == 13 { carriageReturns += 1; continue }
            // Legacy ADB can apply the LF -> CRLF conversion twice. Leave lone
            // CR and unrecognized longer runs intact rather than hiding controls.
            if scalar.value != 10 || carriageReturns > 2 {
                for _ in 0..<carriageReturns { result.append("\r") }
            }
            carriageReturns = 0; result.append(scalar)
        }
        for _ in 0..<carriageReturns { result.append("\r") }
        return String(result)
    }
    static func decode(_ data: Data) -> String { normalize(String(decoding: data, as: UTF8.self)) }
}
