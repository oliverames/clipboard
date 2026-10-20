//
//  CodeDetector.swift
//  ClipKit
//
//  Created by Oliver Ames on 10/20/26.
//

import Foundation

/// A programming or markup language that `CodeDetector` can recognize.
public enum CodeLanguage: String, CaseIterable
{
    case swift
    case objectiveC
    case javascript
    case typescript
    case python
    case ruby
    case go
    case rust
    case java
    case kotlin
    case c
    case cpp
    case csharp
    case php
    case shell
    case sql
    case html
    case css
    case json
    case yaml
    case xml
    case perl
    case lua
    case dart
    case scala
    case haskell
    case elixir
    case r

    /// The language's proper name. These are names rather than prose, so they aren't localized.
    public var displayName: String
    {
        switch self
        {
        case .swift: return "Swift"
        case .objectiveC: return "Objective-C"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .python: return "Python"
        case .ruby: return "Ruby"
        case .go: return "Go"
        case .rust: return "Rust"
        case .java: return "Java"
        case .kotlin: return "Kotlin"
        case .c: return "C"
        case .cpp: return "C++"
        case .csharp: return "C#"
        case .php: return "PHP"
        case .shell: return "Shell"
        case .sql: return "SQL"
        case .html: return "HTML"
        case .css: return "CSS"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .xml: return "XML"
        case .perl: return "Perl"
        case .lua: return "Lua"
        case .dart: return "Dart"
        case .scala: return "Scala"
        case .haskell: return "Haskell"
        case .elixir: return "Elixir"
        case .r: return "R"
        }
    }
}

private typealias Signal = (pattern: String, weight: Int)

/// Guesses which language a piece of text is written in, or whether it's code at all.
///
/// Each language is scored on distinctive tokens and patterns, each worth a weight. The highest score wins
/// if it reaches `minimumScore`. Ties go to the language declared first in `CodeLanguage`.
/// Text on a single line also needs one strong signal (weight `strongWeight` or more), so a short phrase isn't mistaken for code.
public enum CodeDetector
{
    private static let minimumScore = 4
    private static let strongWeight = 6

    /// Returns the most likely language, or nil if the text doesn't look like code.
    public static func detect(_ text: String) -> CodeLanguage?
    {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if isJSON(trimmed) { return .json }

        let isMultiline = trimmed.contains { $0.isNewline }
        let range = NSRange(trimmed.startIndex..., in: trimmed)

        var best: (language: CodeLanguage, score: Int)?
        for (language, signals) in rules
        {
            var score = 0
            var strongest = 0

            for rule in signals where rule.regex.firstMatch(in: trimmed, range: range) != nil
            {
                score += rule.weight
                strongest = max(strongest, rule.weight)
            }

            guard score >= minimumScore, isMultiline || strongest >= strongWeight else { continue }
            if score > (best?.score ?? 0) { best = (language, score) }
        }

        return best?.language
    }
}

private extension CodeDetector
{
    static let rules: [(language: CodeLanguage, signals: [(regex: NSRegularExpression, weight: Int)])] = CodeLanguage.allCases.compactMap { language in
        let signals = signals(for: language)
        guard !signals.isEmpty else { return nil }

        // The patterns are constants, so a failure here is a programmer error that the tests would catch.
        let compiled = signals.map { (regex: try! NSRegularExpression(pattern: $0.pattern, options: [.anchorsMatchLines]), weight: $0.weight) }
        return (language, compiled)
    }

    static func isJSON(_ text: String) -> Bool
    {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return object is [Any] || object is [String: Any]
    }

    static let javascriptSignals: [Signal] = [
        (#"\bfunction\s*\w*\s*\("#, 3),
        (#"\b(const|let|var)\s+\w+\s*="#, 2),
        (#"=>\s*[{(\w]"#, 2),
        (#"===|!=="#, 2),
        (#"\bconsole\.(log|error|warn|info)\("#, 6),
        (#"\bmodule\.exports\b|\brequire\("#, 4),
        (#"\bimport\s+.+\s+from\s+['"]"#, 4),
        (#"\bexport\s+(default|const|function|class)\b"#, 4),
        (#"\bdocument\.(getElementById|querySelector)"#, 5),
    ]

    static let cSignals: [Signal] = [
        (#"^\s*#\s*include\s*[<"]"#, 4),
        (#"^\s*#\s*(define|ifdef|ifndef|endif|pragma)\b"#, 3),
        (#"\bint\s+main\s*\("#, 3),
        (#"\b(int|void|char|double|float|long)\s+\w+\s*\([^)]*\)\s*\{"#, 2),
    ]

    /// Distinctive tokens for each language. Weights run from 1 (common elsewhere) to 10 (nearly unique, like `<?php`).
    static func signals(for language: CodeLanguage) -> [Signal]
    {
        switch language
        {
        case .swift:
            return [
                (#"\bfunc\s+\w+\s*(<[^>]*>)?\s*\([^)]*\)\s*(async\s+)?(throws\s+)?->"#, 6),
                (#"\bfunc\s+\w+\s*(<[^>]*>)?\s*\([^)]*\w\s*:\s*\w"#, 3),
                (#"\b(let|var)\s+\w+\s*:\s*[A-Z\[]\w*"#, 3),
                (#"^\s*import\s+(Foundation|UIKit|SwiftUI|AppKit|Combine|CoreData|XCTest|Swift)\b"#, 6),
                (#"\bguard\s+.+\s+else\s*\{"#, 5),
                (#"\bif\s+let\s+\w+"#, 5),
                (#"@(State|Binding|Published|ObservedObject|StateObject|Environment|main|MainActor|IBOutlet|IBAction)\b"#, 5),
                (#"\bvar\s+body\s*:\s*some\s+View"#, 8),
                (#"\b(protocol|extension)\s+\w+"#, 3),
                (#"\bstruct\s+\w+\s*:\s*\w+"#, 3),
            ]

        case .objectiveC:
            return [
                (#"^\s*#import\s+[<"]"#, 6),
                (#"@(interface|implementation|protocol)\s+\w+"#, 6),
                (#"^\s*@end\s*$"#, 4),
                (#"@property\s*\("#, 6),
                (#"^\s*[-+]\s*\(\s*\w+\s*\*?\s*\)\s*\w+"#, 5),
                (#"\[\[\w+\s+alloc\]\s+init\w*\]"#, 6),
                (#"\bNS[A-Z]\w+\s*\*"#, 5),
                (#"@["][^"\n]*["]"#, 3),
                (#"\bNSLog\(@"#, 6),
                (#"\b(YES|NO)\b"#, 2),
            ]

        case .javascript:
            return javascriptSignals

        case .typescript:
            return javascriptSignals + [
                (#"\binterface\s+\w+(<[^>]*>)?\s*(extends\s+[\w, ]+)?\{"#, 3),
                (#"\b(const|let|var)\s+\w+\s*:\s*(string|number|boolean|any|unknown|void|never|object)\b"#, 5),
                (#"\b(const|let|var)\s+\w+\s*:\s*[\w.]+(\[\]|<[^>]*>)"#, 4),
                (#"\)\s*:\s*(string|number|boolean|void|any|unknown|Promise<[^>]*>|\w+\[\])\s*(=>|\{)"#, 5),
                (#"\w\s*:\s*(string|number|boolean)\s*[;,)]"#, 3),
                (#"\btype\s+\w+(<[^>]*>)?\s*=\s*[{|\w]"#, 2),
                (#"\bas\s+(string|number|any|unknown|const)\b"#, 3),
                (#"\bimport\s+type\b|\bexport\s+(interface|type)\b"#, 6),
                (#"\breadonly\s+\w+\s*:"#, 4),
                (#"\benum\s+\w+\s*\{"#, 2),
            ]

        case .python:
            return [
                (#"^\s*def\s+\w+\s*\([^)]*\)\s*(->\s*[^:\n]+)?:\s*$"#, 5),
                (#"^\s*class\s+\w+\s*(\([^)]*\))?\s*:\s*$"#, 4),
                (#"^\s*from\s+[\w.]+\s+import\s+\w"#, 4),
                (#"^\s*import\s+[\w.]+(\s+as\s+\w+)?\s*$"#, 2),
                (#"^\s*(elif\b.*|else|try|finally)\s*:\s*$"#, 3),
                (#"^\s*(if|for|while|with|except)\b[^\n{};]*:\s*$"#, 2),
                (#"\bif\s+__name__\s*==\s*['"]__main__['"]"#, 8),
                (#"\bself\.\w+"#, 2),
                (#"\bprint\("#, 1),
                (#"\b(True|False|None)\b"#, 1),
                (#"\bf["'][^"'\n]*\{\w"#, 3),
            ]

        case .ruby:
            return [
                (#"^\s*def\s+\w+[?!=]?(\([^)]*\))?\s*$"#, 4),
                (#"^\s*class\s+[A-Z]\w*(\s*<\s*[\w:]+)?\s*$"#, 4),
                (#"^\s*module\s+[A-Z][\w:]*\s*$"#, 4),
                (#"^\s*end\s*$"#, 2),
                (#"\bputs\s+[\w'"]"#, 3),
                (#"^\s*require(_relative)?\s+['"]"#, 5),
                (#"\battr_(accessor|reader|writer)\b"#, 6),
                (#"\bdo\s*\|[\w, ]+\|"#, 6),
                (#"\.each(_with_index)?\b"#, 1),
                (#"\bunless\b|\belsif\b"#, 3),
                (#"@\w+\s*=[^=]"#, 2),
                (#":\w+\s*=>"#, 2),
                (#"#\{[^}]+\}"#, 2),
            ]

        case .go:
            return [
                (#"^\s*package\s+main\s*$"#, 6),
                (#"^\s*package\s+[a-z]\w*\s*$"#, 3),
                (#"^\s*import\s+(\(|["])"#, 4),
                (#"\bfunc\s+(\([^)]*\)\s*)?\w+\s*\([^):\n]*\)[^\n{>-]*\{"#, 3),
                (#"\bfunc\s+main\s*\(\s*\)"#, 5),
                (#":="#, 3),
                (#"\bfmt\.(Print|Printf|Println|Sprintf|Errorf|Fprintf)\("#, 6),
                (#"\bif\s+err\s*!=\s*nil\b"#, 6),
                (#"\btype\s+\w+\s+(struct|interface)\s*\{"#, 6),
                (#"\bdefer\s+\w|\bgo\s+func\s*\(|\bchan\s+\w"#, 4),
                (#"\bmake\((\[\]|map\[|chan\s)"#, 5),
                (#"\[\]\w+\{"#, 3),
            ]

        case .rust:
            return [
                (#"\bfn\s+main\s*\(\s*\)"#, 6),
                (#"\bfn\s+\w+\s*(<[^>]*>)?\s*\("#, 3),
                (#"\blet\s+mut\b"#, 6),
                (#"\buse\s+(std|core|crate|super|self)::"#, 6),
                (#"\bpub\s+(fn|struct|enum|mod|trait|use|const)\b"#, 4),
                (#"\bimpl(\s*<[^>]*>)?\s+\w+"#, 4),
                (#"\b(println|print|eprintln|format|vec|panic|assert_eq|assert)!\s*[(\[]"#, 6),
                (#"&mut\s"#, 3),
                (#"\.unwrap\(\)|\.expect\("#, 3),
                (#"#\[(derive|test|cfg)"#, 6),
                (#"\bfn\s+\w+[^\n]*->\s*\S"#, 2),
                (#"\b(Vec|HashMap|Option|Result|Box)<"#, 3),
                (#"::new\("#, 2),
            ]

        case .java:
            return [
                (#"\bpublic\s+static\s+void\s+main\s*\("#, 8),
                (#"\bSystem\.(out|err)\.print(ln|f)?\("#, 6),
                (#"^\s*import\s+(static\s+)?javax?\.[\w.*]+;"#, 7),
                (#"^\s*package\s+[\w.]+;"#, 4),
                (#"^\s*import\s+[\w.]+(\.\*)?;"#, 3),
                (#"\b(public|private|protected)\s+(abstract\s+|final\s+)*(class|interface|enum)\s+\w+"#, 4),
                (#"\b(public|private|protected)\s+(static\s+)?(final\s+)?[\w<>\[\],? ]+\s+\w+\s*\([^)]*\)\s*(throws\s+[\w, ]+)?\s*\{"#, 3),
                (#"@Override\b"#, 3),
                (#"\bextends\s+\w+|\bimplements\s+\w+"#, 2),
                (#"\bString\[\]\s+\w+"#, 3),
                (#"\bnew\s+(ArrayList|HashMap|HashSet|LinkedList|Thread|Scanner)\b"#, 4),
                (#"\b(List|Map|Set|ArrayList|HashMap)<[\w<>, ?]+>\s+\w+\s*="#, 3),
            ]

        case .kotlin:
            return [
                (#"\bfun\s+(<[^>]*>\s*)?(\w+\.)?\w+\s*\("#, 5),
                (#"\bfun\s+main\s*\("#, 6),
                (#"\b(val|var)\s+\w+(\s*:\s*[\w<>?, ]+)?\s*=\s*"#, 2),
                (#"\bdata\s+class\b|\bsealed\s+(class|interface)\b|\bcompanion\s+object\b|\bsuspend\s+fun\b|\blateinit\s+var\b"#, 7),
                (#"\bwhen\s*(\([^)]*\))?\s*\{"#, 4),
                (#"^\s*import\s+(kotlin|kotlinx|android|androidx)\."#, 6),
                (#"^\s*package\s+[\w.]+\s*$"#, 3),
                (#"\boverride\s+fun\b"#, 6),
                (#"\?\.\w+|\?:\s"#, 2),
                (#"\bprintln\("#, 1),
            ]

        case .c:
            return cSignals + [
                (#"#\s*include\s*<(stdio|stdlib|string|stdint|stdbool|unistd|math|assert|errno|ctype|time)\.h>"#, 3),
                (#"\b(printf|fprintf|scanf|malloc|calloc|free|strlen|strcpy|memcpy)\s*\("#, 2),
                (#"\btypedef\s+(struct|enum|union)\b"#, 4),
                (#"\b(unsigned|signed)\s+(int|char|long)\b|\bsize_t\b|\buint(8|16|32|64)_t\b"#, 3),
                (#"\bstruct\s+\w+\s*\*"#, 3),
                (#"\bchar\s*\*\s*\w+|\bchar\s+\w+\s*\["#, 3),
                (#"\bvoid\s*\*"#, 2),
            ]

        case .cpp:
            return cSignals + [
                (#"\bstd::\w+"#, 5),
                (#"#\s*include\s*<(iostream|vector|string|map|set|unordered_map|memory|algorithm|fstream|sstream|cstdio|cstdlib|cmath|optional|functional|thread|array)>"#, 5),
                (#"\bcout\s*<<|\bcin\s*>>"#, 5),
                (#"^\s*using\s+namespace\s+\w+"#, 6),
                (#"\btemplate\s*<[^>]*>"#, 5),
                (#"\bnamespace\s+\w+\s*\{"#, 4),
                (#"\b(class|struct)\s+\w+\s*(:\s*(public|private|protected)\s+\w+)?\s*\{"#, 2),
                (#"\b(public|private|protected)\s*:"#, 4),
                (#"\b(nullptr|constexpr|noexcept|decltype)\b"#, 5),
                (#"\bauto\s+&?\w+\s*="#, 3),
                (#"\b(unique_ptr|shared_ptr|make_unique|make_shared)\b"#, 5),
                (#"\bvirtual\b|\boverride\b"#, 2),
            ]

        case .csharp:
            return [
                (#"^\s*using\s+System(\.[\w.]+)?\s*;"#, 7),
                (#"^\s*using\s+[\w.]+\s*;"#, 3),
                (#"\bConsole\.(WriteLine|Write|ReadLine)\("#, 7),
                (#"^\s*namespace\s+[\w.]+\s*(\{|;)?\s*$"#, 3),
                (#"\{\s*get;(\s*(private\s+|protected\s+)?(set|init);)?\s*\}"#, 6),
                (#"\b(public|private|protected|internal)\s+(static\s+|abstract\s+|sealed\s+|partial\s+)*(class|interface|struct|enum|record)\s+\w+"#, 4),
                (#"\b(public|private|protected|internal)\s+(static\s+)?(async\s+)?[\w<>\[\],? ]+\s+\w+\s*\([^)]*\)\s*(\{|=>)"#, 3),
                (#"\bforeach\s*\(\s*(var|\w+)\s+\w+\s+in\b"#, 5),
                (#"\basync\s+Task\b|\bawait\s+\w+\.\w+Async\("#, 5),
                (#"^\s*\[\w+(\(.*\))?\]\s*$"#, 2),
                (#"\bstring\s+\w+\s*="#, 2),
                (#"\bvar\s+\w+\s*=\s*new\s+\w+"#, 3),
                (#"\bpublic\s+override\b|\bvirtual\b"#, 3),
            ]

        case .php:
            return [
                (#"<\?php"#, 10),
                (#"<\?="#, 5),
                (#"\$this->\w+"#, 5),
                (#"\$_(GET|POST|REQUEST|SERVER|SESSION|COOKIE)\b"#, 6),
                (#"^\s*\$\w+\s*=[^=~]"#, 2),
                (#"\b(public|private|protected)\s+(static\s+)?function\s+\w+"#, 6),
                (#"\bfunction\s+\w*\s*\(\s*(\??\w+\s+)?&?\$\w+"#, 5),
                (#"\bforeach\s*\(\s*\$\w+\s+as\b"#, 6),
                (#"\b(echo|print)\s+[\"'$]"#, 2),
                (#"\b(isset|array_\w+|var_dump|print_r|json_encode|json_decode|str_replace|strlen|explode|implode)\("#, 5),
                (#"^\s*(namespace|use)\s+\\?[A-Z]\w*(\\\w+)+\s*(as\s+\w+\s*)?;"#, 5),
                (#"['"]\s*=>\s*"#, 2),
                (#"::class\b|\bself::|\bstatic::|\bparent::"#, 3),
            ]

        case .shell:
            let commands = "sudo|apt|apt-get|brew|npm|npx|pip|pip3|git|cd|ls|mkdir|rm|cp|mv|chmod|chown|curl|wget|cat|grep|docker|kubectl"
            return [
                (#"^#!\s*/(usr/)?bin/(env\s+)?(ba|z|da|k)?sh\b"#, 10),
                (#"\becho\s+["']?\$"#, 6),
                (#"^\s*echo\s+\S"#, 3),
                (#"^\s*(if|elif)\s+\[\[?\s"#, 5),
                (#"^\s*fi\s*$"#, 4),
                (#"^\s*(done|esac)\s*$"#, 3),
                (#"^\s*for\s+\w+\s+in\s+[^\n]*;\s*do\b"#, 5),
                (#"^\s*while\s+(read\b|\[)"#, 4),
                (#"^\s*(export|local|readonly)\s+[A-Za-z_]\w*="#, 4),
                (#"\|\s*(grep|awk|sed|xargs|sort|uniq|wc|cut|head|tail|tr|tee|jq)\b"#, 4),
                (#"^\s*(\#(commands))\s+[-./~\w]"#, 2),
                (#"^\s*(\#(commands))\s+\S[^\n]*\n\s*(\#(commands))\s+\S"#, 4),
                (#"\$\([^)\n]+\)"#, 3),
                (#"\$\{\w+(:[-=?+]|#|%|/)[^}]*\}"#, 3),
                (#"\s2>&1|>\s*/dev/null"#, 4),
                (#"\[\s+-[a-z]\s+\S+\s+\]"#, 4),
                (#"^\s*\w+\(\)\s*\{\s*$"#, 3),
                (#";\s*then\s*$"#, 3),
            ]

        case .sql:
            return [
                (#"\bSELECT\b[^;]*\bFROM\b"#, 7),
                (#"\bINSERT\s+INTO\b|\bDELETE\s+FROM\b|\bCREATE\s+(TABLE|INDEX|VIEW|DATABASE|UNIQUE)\b|\bALTER\s+TABLE\b|\bDROP\s+(TABLE|INDEX|VIEW|DATABASE)\b"#, 7),
                (#"\bUPDATE\s+\w+\s+SET\b"#, 7),
                (#"\b(INNER|LEFT|RIGHT|FULL|OUTER|CROSS)\s+JOIN\b"#, 4),
                (#"\b(WHERE|GROUP\s+BY|ORDER\s+BY|HAVING|LIMIT|VALUES)\b"#, 2),
                (#"(?i)\bselect\s+(\*|[\w.]+(\s*,\s*[\w.]+)*)\s+from\s+\w+"#, 3),
                (#"(?i)\b(insert\s+into|delete\s+from|create\s+table|alter\s+table|drop\s+table)\s+\w+"#, 3),
                (#"(?i)\bwhere\s+\w+\s*(=|<|>|<>|!=|\blike\b|\bin\s*\()"#, 2),
                (#"(?i)\b(primary\s+key|not\s+null|varchar\(\d+\)|foreign\s+key|auto_increment)\b"#, 4),
                (#"^\s*--"#, 1),
            ]

        case .html:
            return [
                (#"(?i)<!DOCTYPE\s+html"#, 10),
                (#"(?i)<html\b"#, 6),
                (#"(?i)</(div|span|p|a|ul|ol|li|body|head|html|h[1-6]|table|tr|td|th|section|nav|form|button|script|style|label|select|option|header|footer|main|article|title)>"#, 6),
                (#"(?i)<(div|span|p|a|ul|ol|li|h[1-6]|table|section|nav|form|button|input|img|link|meta|script|style|label|header|footer|main|article|br|hr)\b[^>]*>"#, 3),
                (#"<\w+\s+(class|id|href|src|style|type|name|rel|alt|value)=["']"#, 3),
                (#"<([A-Za-z][\w-]*)\b[^>]*>[^<\n]*</\1>"#, 3),
            ]

        case .css:
            return [
                (#"@(media|import|font-face|keyframes|charset|supports)\b"#, 6),
                (#"\b(color|background(-color)?|margin(-\w+)?|padding(-\w+)?|font(-size|-family|-weight)?|display|border(-\w+)?|width|height|position|text-align|line-height|opacity|z-index|flex(-\w+)?|justify-content|align-items|overflow|cursor)\s*:\s*[^;{}\n]+;"#, 4),
                (#"^\s*[.#][\w-]+(\s*[,>+~ ]\s*[.#:]?[\w-]+)*\s*\{"#, 4),
                (#"\{[^{}]*\b(color|background|margin|padding|font-size|display|border|width|height)\s*:[^{}]*\}"#, 6),
            ]

        case .json:
            // Detected by parsing rather than by scoring.
            return []

        case .yaml:
            return [
                (#"^---\s*$"#, 3),
                (#"^[\w-]+:[ \t]*\n[ \t]+[\w-]+:"#, 4),
                (#"^[\w-]+:[ \t]*\n[ \t]*-[ \t]+\S"#, 4),
                (#"^[\w-]+:[ \t]+\S([^\n]*[^\n,;{(\s])?[ \t]*(\n[\w-]+:[ \t]+\S([^\n]*[^\n,;{(\s])?[ \t]*)+$"#, 4),
                (#"^\s*-[ \t]+[\w-]+:[ \t]+\S"#, 3),
                (#"^[\w-]+:\s+[|>][-+]?\s*$"#, 4),
            ]

        case .xml:
            return [
                (#"<\?xml\s"#, 10),
                (#"\bxmlns(:\w+)?=["']"#, 6),
                (#"<!\[CDATA\["#, 6),
                (#"^\s*<[\w:.-]+(\s+[\w:.-]+=["'][^"']*["'])*\s*/?>\s*$"#, 2),
                (#"^\s*</[\w:.-]+>\s*$"#, 2),
                (#"<!--.*-->"#, 1),
                (#"<([\w:.-]+)\b[^>]*>[^<\n]*</\1>"#, 6),
            ]

        case .perl:
            return [
                (#"^#!\s*/(usr/)?bin/(env\s+)?perl\b"#, 10),
                (#"^\s*use\s+(strict|warnings|utf8|feature|POSIX|Data::Dumper)\b"#, 7),
                (#"\bmy\s+[$@%]\w+"#, 6),
                (#"\bsub\s+\w+\s*\{"#, 6),
                (#"=~\s*(m|s|tr|y)?[/{|!]"#, 5),
                (#"\bforeach\s+my\b"#, 6),
                (#"\bprint\s+["'][^"']*["']\s*;"#, 2),
                (#"@\w+\s*=\s*\("#, 3),
                (#"\$\w+\{\w+\}|\$\w+->\{"#, 3),
                (#"\belsif\b"#, 3),
                (#"\bdie\s+["']"#, 3),
                (#"<STDIN>|<\$\w+>"#, 5),
                (#"\bchomp\b"#, 4),
                (#"\bkeys\s+%"#, 5),
            ]

        case .lua:
            return [
                (#"^#!\s*/(usr/)?bin/(env\s+)?lua\b"#, 10),
                (#"\blocal\s+(function\s+)?\w+"#, 5),
                (#"\bfunction\s+[\w.:]+\s*\([^)]*\)\s*$"#, 4),
                (#"^\s*end\s*[,)]?\s*$"#, 2),
                (#"^\s*(el)?if\s+[^\[;\n]+\bthen\s*$"#, 4),
                (#"~="#, 3),
                (#"[\w"']\s+\.\.\s+[\w"']"#, 3),
                (#"\bipairs\(|\bpairs\(|\btable\.(insert|remove|concat|sort)\b|\bstring\.(format|sub|gsub|find)\b"#, 6),
                (#"\bfor\s+\w+\s*=\s*[^,\n]+,\s*[^\n]+\bdo\b|\bfor\s+\w+(\s*,\s*\w+)?\s+in\s+[^\n]+\bdo\s*$"#, 5),
                (#"^\s*while\s+.+\s+do\s*$"#, 3),
                (#"\bnil\b"#, 1),
                (#"\bprint\("#, 1),
                (#"^\s*--"#, 1),
            ]

        case .dart:
            return [
                (#"^\s*import\s+['"](package|dart):"#, 8),
                (#"^\s*import\s+['"][^'"]+\.dart['"]"#, 8),
                (#"\bvoid\s+main\s*\(\s*\)"#, 5),
                (#"\bWidget\s+build\(BuildContext"#, 9),
                (#"\bextends\s+(State|StatelessWidget|StatefulWidget)\b"#, 8),
                (#"@override\b"#, 3),
                (#"\bFuture<[\w<>?]*>|\bStream<"#, 5),
                (#"\bsetState\("#, 6),
                (#"\blate\s+(final\s+)?\w+"#, 4),
                (#"\bfinal\s+(\w+\s+)?\w+\s*="#, 2),
                (#"\b(int|String|double|bool)\?\s+\w+"#, 3),
                (#"\bconst\s+[A-Z]\w+\("#, 4),
                (#"\bprint\("#, 1),
            ]

        case .scala:
            return [
                (#"\bdef\s+\w+\s*(\[[^\]]*\])?\s*(\([^)]*\))*\s*(:\s*[\w\[\], ]+)?\s*=\s*"#, 4),
                (#"\bcase\s+class\b|\bsealed\s+trait\b|\bobject\s+\w+\s+extends\b|\bextends\s+App\b|\bimplicit\b"#, 7),
                (#"^\s*import\s+(scala|akka|cats|zio)\."#, 6),
                (#"^\s*import\s+[\w.]+\._\s*$|^\s*import\s+[\w.]+\.\{"#, 5),
                (#"\bobject\s+\w+\s*(extends\b|\{)"#, 3),
                (#"\btrait\s+\w+"#, 3),
                (#"\b\w+\s+match\s*\{"#, 5),
                (#"^\s*case\s+[^\n]*=>"#, 4),
                (#"\bval\s+\w+(\s*:\s*[\w\[\], ]+)?\s*="#, 2),
                (#"\bprintln\("#, 1),
            ]

        case .haskell:
            return [
                (#"^\s*module\s+[\w.]+(\s*\(.*\))?\s+where\b"#, 8),
                (#"^\s*import\s+(qualified\s+)?[A-Z][\w.]*(\s+(as|hiding)\s+.+|\s*\(.*\))?\s*$"#, 3),
                (#"^[a-z]\w*'?\s+::\s+[A-Z(\[\w][^\n]*$"#, 6),
                (#"\bdata\s+[A-Z]\w*(\s+\w+)*\s*=\s*[A-Z]"#, 5),
                (#"^\s+where\b"#, 3),
                (#"\bnewtype\b|\binstance\s+[A-Z]\w+\s+[A-Z]"#, 5),
                (#"\bputStrLn\b|\bgetLine\b"#, 6),
                (#"\blet\s+\w+\s*=\s*.+\bin\b"#, 3),
                (#"\{-.*-\}"#, 4),
                (#"<-\s"#, 1),
                (#"^\s*--"#, 1),
            ]

        case .elixir:
            return [
                (#"\bdefmodule\s+[\w.]+\s+do\b"#, 8),
                (#"^\s*defp?\s+\w+[?!]?(\([^)]*\))?(\s+when\s+[^\n]+)?\s+do\s*$"#, 6),
                (#"\|>\s"#, 4),
                (#"\bIO\.(puts|inspect)\b"#, 6),
                (#"^\s*@(moduledoc|doc|spec|impl|behaviour)\b"#, 6),
                (#"\bcase\s+[^\n]+\s+do\s*$"#, 4),
                (#"%\{[^}\n]*\}|%\w+\{"#, 3),
                (#":ok\b|:error\b|\{:\w+,"#, 3),
                (#"\bfn\s+[\w, ()]*->"#, 5),
                (#"^\s*end\s*$"#, 2),
                (#"\bdo\s*$"#, 2),
                (#"^\s*use\s+[A-Z][\w.]*\s*(,.*)?$"#, 3),
                (#"#\{[^}]+\}"#, 2),
                (#"\b(Enum|Map|String|List)\.\w+\("#, 2),
            ]

        case .r:
            return [
                (#"\blibrary\(\s*\w+\s*\)"#, 7),
                (#"\w+\s*<-\s*function\s*\("#, 8),
                (#"\b\w+\s*<-\s*\S"#, 3),
                (#"%>%"#, 8),
                (#"\bdata\.frame\(|\bggplot\(|\baes\(|\bread\.csv\(|\bsetwd\(|\bsapply\(|\blapply\("#, 8),
                (#"\bc\(\s*[\d"'-]"#, 2),
                (#"\b(TRUE|FALSE)\b"#, 2),
                (#"\bpaste0?\("#, 5),
                (#"\w+\[\[.+\]\]"#, 2),
                (#"\bcat\(["']"#, 3),
            ]
        }
    }
}
