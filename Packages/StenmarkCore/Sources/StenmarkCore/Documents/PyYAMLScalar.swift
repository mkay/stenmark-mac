// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Writes a string as PyYAML's `yaml.dump` would in a block sequence.
///
/// The Linux app writes tags with PyYAML. A Swift YAML library quotes things
/// differently, so a tag edit on the Mac would reformat a note for no reason
/// and send it round through sync. This follows `Emitter.analyze_scalar` and
/// the implicit resolvers in PyYAML, and the fixtures check it against the real
/// thing. PyYAML also folds plain scalars at 80 columns; a tag that long stays
/// on one line here, which reads back the same.
enum PyYAMLScalar {
    static func string(_ value: String) -> String {
        let analysis = analyze(value)
        if analysis.allowPlain, !resolvesToOtherType(value) {
            return value
        }
        if analysis.allowSingleQuoted {
            return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }
        return doubleQuoted(value)
    }

    private struct Analysis {
        var allowPlain: Bool
        var allowSingleQuoted: Bool
    }

    private static func analyze(_ value: String) -> Analysis {
        let scalars = Array(value.unicodeScalars)
        guard !scalars.isEmpty else { return Analysis(allowPlain: true, allowSingleQuoted: true) }

        var blockIndicators = value.hasPrefix("---") || value.hasPrefix("...")
        var specialCharacters = false
        var precededByWhitespace = true

        for (index, scalar) in scalars.enumerated() {
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            let followedByWhitespace = next.map(isWhitespace) ?? true

            if index == 0 {
                if "#,[]{}&*!|>'\"%@`".unicodeScalars.contains(scalar) { blockIndicators = true }
                if (scalar == "?" || scalar == ":" || scalar == "-"), followedByWhitespace {
                    blockIndicators = true
                }
            } else {
                if scalar == ":", followedByWhitespace { blockIndicators = true }
                if scalar == "#", precededByWhitespace { blockIndicators = true }
            }
            if !isPrintable(scalar) { specialCharacters = true }
            precededByWhitespace = isWhitespace(scalar)
        }

        let edgeSpace = scalars.first == " " || scalars.last == " "
        return Analysis(
            allowPlain: !blockIndicators && !specialCharacters && !edgeSpace,
            allowSingleQuoted: !specialCharacters
        )
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        [0, 0x20, 0x09, 0x0D, 0x0A, 0x85, 0x2028, 0x2029].contains(scalar.value)
    }

    private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value == 0xFEFF { return false }
        return (0x20...0x7E).contains(value) || value == 0x85
            || (0xA0...0xD7FF).contains(value) || (0xE000...0xFFFD).contains(value)
            || (0x10000..<0x10FFFF).contains(value)
    }

    private static func doubleQuoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default:
                if isPrintable(scalar) {
                    out.unicodeScalars.append(scalar)
                } else if scalar.value <= 0xFF {
                    out += String(format: "\\x%02X", scalar.value)
                } else {
                    out += String(format: "\\u%04X", scalar.value)
                }
            }
        }
        return out + "\""
    }

    /// PyYAML's implicit resolvers: a plain scalar matching one of these would
    /// read back as a number, a date and so on, so it has to be quoted.
    private static let resolvers: [NSRegularExpression] = [
        #"^(?:yes|Yes|YES|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF)$"#,
        #"^(?:[-+]?(?:[0-9][0-9_]*)\.[0-9_]*(?:[eE][-+][0-9]+)?|\.[0-9][0-9_]*(?:[eE][-+][0-9]+)?|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$"#,
        #"^(?:[-+]?0b[0-1_]+|[-+]?0[0-7_]+|[-+]?(?:0|[1-9][0-9_]*)|[-+]?0x[0-9a-fA-F_]+|[-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+)$"#,
        #"^(?:<<|=|~|null|Null|NULL|)$"#,
        #"^(?:[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}(?:[Tt]|[ \t]+)[0-9]{1,2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]*)?(?:[ \t]*(?:Z|[-+][0-9]{1,2}(?::[0-9]{2})?))?)$"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private static func resolvesToOtherType(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return resolvers.contains { $0.firstMatch(in: value, range: range) != nil }
    }
}
