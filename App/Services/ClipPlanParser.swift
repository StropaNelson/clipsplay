import Foundation

/// Pulls the first balanced JSON object out of a model answer. Chat models
/// sometimes wrap the plan in prose or a ```json fence even when told not to —
/// this finds the outermost `{...}` whose braces balance while ignoring braces
/// inside string literals (and backslash escapes inside them).
enum ClipPlanParser {
    /// Strips an optional ```json fence first, then returns the substring from
    /// the first `{` to its matching `}`. `nil` when no balanced object exists.
    static func extractJSON(from text: String) -> String? {
        let stripped = stripCodeFences(text)
        guard let start = stripped.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < stripped.endIndex {
            let char = stripped[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else if char == "\"" {
                inString = true
            } else if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 {
                    return String(stripped[start...index])
                }
            }
            index = stripped.index(after: index)
        }
        return nil
    }

    /// Removes a ```lang / ``` wrapper when the trimmed answer starts with one.
    /// Text that doesn't open with a fence is returned trimmed but untouched.
    static func stripCodeFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.hasPrefix("```") else { return result }
        result = String(result.dropFirst(3))
        // Optional language tag right after the backticks (```json).
        while result.first?.isLetter == true {
            result = String(result.dropFirst())
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
