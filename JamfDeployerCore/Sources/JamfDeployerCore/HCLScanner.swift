import Foundation

/// Follows HCL line by line far enough to count the braces and brackets that
/// structure it: those inside quoted strings (with `\` escapes), template
/// interpolations (`${ … }`, `%{ … }`), heredocs (`<<EOF`, `<<-EOF`) and
/// comments (`#`, `//`, `/* … */`) don't count. Not a parser: the capture
/// and prune surgery only needs to know where objects open and close.
nonisolated struct HCLScanner {
    private enum Context { case string, interpolation(depth: Int) }

    /// Open `{` minus closed `}` in code so far.
    private(set) var braces = 0
    /// Open `[` minus closed `]` in code so far.
    private(set) var brackets = 0
    private var stack: [Context] = []
    private var heredocMarker: String?
    private var inBlockComment = false
    /// A line ended inside a quoted string (HCL strings never span lines).
    private(set) var sawUnterminatedString = false

    /// The next line is heredoc text (a template, not HCL).
    var isInHeredoc: Bool { heredocMarker != nil }

    /// Back at the depth a block started from: no open brace, string or heredoc.
    var isAtTopLevel: Bool { braces <= 0 && heredocMarker == nil && !inBlockComment }

    /// Scans one line; returns its change in (braces, brackets).
    @discardableResult
    mutating func scan<S: StringProtocol>(_ line: S) -> (braces: Int, brackets: Int) {
        let before = (braces, brackets)
        if let marker = heredocMarker {
            if line.trimmingCharacters(in: .whitespaces) == marker { heredocMarker = nil }
            return (0, 0)
        }
        let characters = Array(line)
        var index = 0
        func next(_ offset: Int) -> Character? {
            index + offset < characters.count ? characters[index + offset] : nil
        }
        scanning: while index < characters.count {
            let character = characters[index]
            if inBlockComment {
                if character == "*", next(1) == "/" { inBlockComment = false; index += 1 }
                index += 1
                continue
            }
            switch stack.last {
            case .string:
                if character == "\\" {
                    index += 1
                } else if character == "\"" {
                    stack.removeLast()
                } else if (character == "$" || character == "%"), next(1) == character, next(2) == "{" {
                    index += 2  // $${ and %%{ are literal
                } else if (character == "$" || character == "%"), next(1) == "{" {
                    stack.append(.interpolation(depth: 0))
                    index += 1
                }
            case .interpolation, nil:
                switch character {
                case "\"":
                    stack.append(.string)
                case "#":
                    break scanning
                case "/" where next(1) == "/":
                    break scanning
                case "/" where next(1) == "*":
                    inBlockComment = true
                    index += 1
                case "<" where next(1) == "<" && stack.isEmpty:
                    var rest = String(characters[(index + 2)...])
                    if rest.hasPrefix("-") { rest.removeFirst() }
                    if let marker = rest.firstMatch(of: /^[A-Za-z_][A-Za-z0-9_]*/) {
                        heredocMarker = String(marker.0)
                        break scanning
                    }
                case "{":
                    if case .interpolation(let depth) = stack.last {
                        stack[stack.count - 1] = .interpolation(depth: depth + 1)
                    } else {
                        braces += 1
                    }
                case "}":
                    if case .interpolation(let depth) = stack.last {
                        if depth == 0 { stack.removeLast() } else { stack[stack.count - 1] = .interpolation(depth: depth - 1) }
                    } else {
                        braces -= 1
                    }
                case "[" where stack.isEmpty:
                    brackets += 1
                case "]" where stack.isEmpty:
                    brackets -= 1
                default:
                    break
                }
            }
            index += 1
        }
        if stack.contains(where: { if case .string = $0 { true } else { false } }) {
            // Quoted strings end on their line; start the next one in code.
            sawUnterminatedString = true
            stack.removeAll()
        }
        return (braces - before.0, brackets - before.1)
    }

    /// The line's change in braces alone, without state from earlier lines.
    static func braceDelta<S: StringProtocol>(_ line: S) -> Int {
        var scanner = HCLScanner()
        return scanner.scan(line).braces
    }
}
