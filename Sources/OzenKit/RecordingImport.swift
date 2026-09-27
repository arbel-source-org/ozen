import Foundation

public enum RecordingImport {
    public static func personName(fromFileName fileName: String) -> String? {
        var name = (fileName as NSString).deletingPathExtension
        let trailing = try! NSRegularExpression(pattern: "[\\s_\\-.,()\\[\\]#]*\\d*[\\s_\\-.,()\\[\\]#]*$")
        name = trailing.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: "")
        name = name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    public struct Result: Equatable, Sendable {
        public var added: [String: Int] = [:]
        public var unusable: [String] = []

        public init(added: [String: Int] = [:], unusable: [String] = []) {
            self.added = added
            self.unusable = unusable
        }

        public var summary: String {
            let added = self.added.sorted { $0.key < $1.key }.map { name, count in
                count == 1 ? name : tr("%1 (%2 הקלטות)", "%1 (%2 recordings)", args: ["\(name)", "\(count)"])
            }
            var lines: [String] = []
            if !added.isEmpty {
                lines.append(tr("נוספו: ", "Added: ") + added.joined(separator: ", "))
            }
            if !unusable.isEmpty {
                lines.append(tr("לא נוספו (אין בהן מספיק דיבור, או שאין שם בשם הקובץ): ", "Not added (too little speech, or no name in the file name): ") + unusable.joined(separator: ", "))
            }
            return lines.joined(separator: "\n\n")
        }
    }
}
