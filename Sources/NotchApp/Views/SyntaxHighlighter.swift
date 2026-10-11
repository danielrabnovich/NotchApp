import SwiftUI

/// Colours code in answers: keywords, strings, comments, numbers, types, function calls and
/// decorators, in Xcode's dark palette. One pass over the text; no grammar, just enough to read
/// quickly. The language comes from the fence ("```python"), or is guessed.
enum SyntaxHighlighter {
    enum Language {
        case swift, python, javascript, go, rust, c, shell, sql, ruby, json, yaml, generic
    }

    private enum Palette {
        static let plain = Color.white.opacity(0.9)
        static let keyword = Color(red: 0.99, green: 0.37, blue: 0.64)
        static let string = Color(red: 0.99, green: 0.42, blue: 0.36)
        static let comment = Color(red: 0.51, green: 0.55, blue: 0.6)
        static let number = Color(red: 0.82, green: 0.75, blue: 0.41)
        static let type = Color(red: 0.36, green: 0.85, blue: 1)
        static let function = Color(red: 0.4, green: 0.72, blue: 0.64)
        static let attribute = Color(red: 0.99, green: 0.56, blue: 0.25)
        static let key = Color(red: 0.63, green: 0.6, blue: 1)
    }

    static func language(named name: String?, code: String) -> Language {
        switch name?.lowercased().trimmingCharacters(in: .whitespaces) ?? "" {
        case "swift": return .swift
        case "python", "py", "python3": return .python
        case "javascript", "js", "jsx", "typescript", "ts", "tsx", "mjs", "java", "kotlin", "kt", "csharp", "cs", "c#", "dart", "scala":
            return .javascript
        case "go", "golang": return .go
        case "rust", "rs": return .rust
        case "c", "cpp", "c++", "objc", "objective-c", "h", "hpp", "m": return .c
        case "bash", "sh", "zsh", "shell", "console", "fish": return .shell
        case "sql", "postgres", "mysql", "sqlite": return .sql
        case "ruby", "rb": return .ruby
        case "json", "jsonc": return .json
        case "yaml", "yml", "toml": return .yaml
        case "": return guess(code)
        default: return .generic
        }
    }

    private static func guess(_ code: String) -> Language {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.hasPrefix("{") || c.hasPrefix("["), c.contains("\":") { return .json }
        if c.hasPrefix("#!") || c.hasPrefix("$ ") || c.hasPrefix("brew ") || c.hasPrefix("npm ") || c.hasPrefix("git ") { return .shell }
        if c.contains("func ") && (c.contains("let ") || c.contains("var ") || c.contains("->")) && !c.contains("package ") { return .swift }
        if c.contains("def ") || c.contains("import ") && c.contains(":\n") || c.contains("elif ") || c.contains("print(") { return .python }
        if c.contains("package ") && c.contains("func ") { return .go }
        if c.contains("fn ") && (c.contains("let mut") || c.contains("->") || c.contains("::")) { return .rust }
        if c.contains("const ") || c.contains("=>") || c.contains("function ") || c.contains("console.") { return .javascript }
        if c.uppercased().contains("SELECT ") && c.uppercased().contains(" FROM ") { return .sql }
        if c.contains("#include") { return .c }
        return .generic
    }

    private static func keywords(_ l: Language) -> Set<String> {
        switch l {
        case .swift: ["func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum", "case", "switch", "default", "for", "in", "while", "import", "protocol", "extension", "private", "public", "internal", "fileprivate", "static", "self", "Self", "init", "throws", "throw", "try", "catch", "do", "async", "await", "nil", "true", "false", "some", "any", "where", "break", "continue", "defer", "inout", "mutating", "override", "final", "weak", "lazy", "actor", "is", "as", "typealias", "repeat"]
        case .python: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "None", "True", "False", "self", "global", "nonlocal", "async", "await", "assert", "del"]
        case .javascript: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "class", "extends", "import", "export", "from", "as", "async", "await", "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "this", "null", "undefined", "true", "false", "interface", "type", "enum", "public", "private", "protected", "static", "readonly", "void", "yield", "implements", "package", "val", "fun", "override", "final"]
        case .go: ["func", "package", "import", "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer", "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "select", "nil", "true", "false", "err"]
        case .rust: ["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "match", "if", "else", "for", "in", "while", "loop", "return", "self", "Self", "crate", "super", "as", "where", "async", "await", "move", "ref", "true", "false", "const", "static", "unsafe", "dyn", "Some", "None", "Ok", "Err"]
        case .c: ["int", "char", "float", "double", "void", "long", "short", "unsigned", "signed", "const", "static", "struct", "union", "enum", "typedef", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "sizeof", "NULL", "nullptr", "true", "false", "auto", "class", "public", "private", "protected", "namespace", "using", "template", "new", "delete", "include", "define", "bool", "virtual", "this"]
        case .shell: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function", "return", "export", "local", "echo", "cd", "sudo", "set", "unset", "source", "exit"]
        case .sql: ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "as", "null", "is", "in", "distinct", "count", "primary", "key", "index", "union", "case", "when", "then", "else", "end"]
        case .ruby: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for", "in", "do", "return", "yield", "begin", "rescue", "ensure", "nil", "true", "false", "self", "require", "attr_accessor", "puts"]
        case .json: ["true", "false", "null"]
        case .yaml: ["true", "false", "null", "yes", "no"]
        case .generic: ["if", "else", "for", "while", "return", "function", "func", "def", "class", "let", "var", "const", "import", "true", "false", "null", "nil", "None"]
        }
    }

    static func highlight(_ code: String, language name: String?) -> AttributedString {
        let lang = language(named: name, code: code)
        let words = keywords(lang)
        let lineComments: [String] = switch lang {
        case .python, .shell, .ruby, .yaml: ["#"]
        case .sql: ["--"]
        case .json: []
        default: ["//"]
        }
        let blockComments = [.python, .shell, .ruby, .yaml, .json].contains(lang) ? false : true
        let chars = Array(code)
        var out = AttributedString()
        var i = 0

        func emit(_ s: String, _ color: Color, bold: Bool = false) {
            var a = AttributedString(s)
            a.foregroundColor = color
            if bold { a.font = .system(size: 11.5, weight: .semibold, design: .monospaced) }
            out += a
        }
        func starts(_ s: String, at j: Int) -> Bool {
            let p = Array(s)
            guard j + p.count <= chars.count else { return false }
            return Array(chars[j..<(j + p.count)]) == p
        }

        while i < chars.count {
            let c = chars[i]
            // Comments
            if let marker = lineComments.first(where: { starts($0, at: i) }),
               lang != .shell || i == 0 || chars[i - 1].isWhitespace {
                var j = i
                while j < chars.count, chars[j] != "\n" { j += 1 }
                emit(String(chars[i..<j]), Palette.comment)
                _ = marker
                i = j
                continue
            }
            if blockComments, starts("/*", at: i) {
                var j = i + 2
                while j < chars.count, !starts("*/", at: j) { j += 1 }
                j = min(chars.count, j + 2)
                emit(String(chars[i..<j]), Palette.comment)
                i = j
                continue
            }
            // Strings (triple-quoted too)
            if c == "\"" || c == "'" || (c == "`" && lang == .javascript) {
                let triple = starts(String(repeating: c, count: 3), at: i)
                let close = triple ? String(repeating: c, count: 3) : String(c)
                var j = i + close.count
                while j < chars.count {
                    if chars[j] == "\\" { j += 2; continue }
                    if starts(close, at: j) { j += close.count; break }
                    if !triple, c != "`", chars[j] == "\n" { break }
                    j += 1
                }
                j = min(j, chars.count)
                // A JSON or YAML key: the string right before a colon.
                var k = j
                while k < chars.count, chars[k] == " " { k += 1 }
                let isKey = (lang == .json || lang == .yaml) && k < chars.count && chars[k] == ":"
                emit(String(chars[i..<j]), isKey ? Palette.key : Palette.string)
                i = j
                continue
            }
            // Numbers
            if c.isNumber, i == 0 || !(chars[i - 1].isLetter || chars[i - 1] == "_") {
                var j = i
                while j < chars.count, chars[j].isHexDigit || chars[j] == "." || chars[j] == "_" || chars[j] == "x" { j += 1 }
                emit(String(chars[i..<j]), Palette.number)
                i = j
                continue
            }
            // Decorators and attributes (@main, @property, #[derive])
            if c == "@" || (c == "#" && lang == .rust && starts("#[", at: i)) {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "[" { j += 1 }
                emit(String(chars[i..<j]), Palette.attribute)
                i = j
                continue
            }
            // Words: keywords, types, calls
            if c.isLetter || c == "_" || (c == "$" && lang == .shell) {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                var k = j
                while k < chars.count, chars[k] == " " { k += 1 }
                let lookup = lang == .sql ? word.lowercased() : word
                if words.contains(lookup) {
                    emit(word, Palette.keyword, bold: true)
                } else if c == "$" {
                    emit(word, Palette.type)
                } else if k < chars.count, chars[k] == "(" {
                    emit(word, Palette.function)
                } else if c.isUppercase, lang != .sql, lang != .yaml, lang != .shell {
                    emit(word, Palette.type)
                } else if lang == .yaml, k < chars.count, chars[k] == ":" {
                    emit(word, Palette.key)
                } else {
                    emit(word, Palette.plain)
                }
                i = j
                continue
            }
            // Everything else, up to the next interesting character.
            var j = i + 1
            while j < chars.count, !(chars[j].isLetter || chars[j].isNumber || "\"'`/#@_-$".contains(chars[j])) { j += 1 }
            emit(String(chars[i..<j]), Palette.plain)
            i = j
        }
        return out
    }
}
