import Foundation

/// Full-screen programs (Claude Code, tmux) break long URLs with a real newline and an
/// indent instead of letting the terminal soft-wrap them. Copied text rejoins those
/// pieces so the pasted link is whole; ordinary line breaks are kept.
public enum WrappedLinks {
    private static let urlCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-._~:/?#[]@!$&'()*+,;=%"))

    /// `columns` is the terminal width; a row counts as full within `margin` cells of it.
    public static func join(_ text: String, columns: Int, margin: Int = 4) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 1, columns > 0 else { return text }
        var result = lines[0]
        for index in 1..<lines.count {
            let previous = lines[index - 1], rest = lines[index].drop(while: { $0 == " " || $0 == "\t" })
            let head = rest.prefix(while: { !$0.isWhitespace })
            let tail = result.split(whereSeparator: \.isWhitespace).last ?? ""
            let path = head.contains(where: { "/?=&#%".contains($0) })
            // A plain word after a URL that happened to end at the edge is new text, not a fragment.
            let fragment = path || head.contains(where: { ".-_~".contains($0) || $0.isNumber }) || head.count == rest.count
            // The first copied line may start mid-row, so its width says nothing; demand a path piece.
            let continued = previous.count >= columns - margin ? fragment : index == 1 && path
            if !head.isEmpty, tail.contains("://"), previous.last?.isWhitespace == false,
               head.unicodeScalars.allSatisfy(urlCharacters.contains), continued {
                result += rest
            } else {
                result += "\n" + lines[index]
            }
        }
        return result
    }
}
