import Foundation

@main
struct PTXParserMain {
    static func main() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: ptx_parse_test <file.ptx>\n", stderr)
            exit(1)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        do {
            var session = try PTXParser.parse(url: url)
            PTXParser.resolveAudioFiles(session: &session, sessionURL: url)
            PTXParser.writeClipLog(session: session, sessionURL: url)
        } catch {
            fputs("Parse error: \(error)\n", stderr)
            exit(1)
        }
    }
}
