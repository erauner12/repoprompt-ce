import Foundation

final class HeadlessStdioTransport {
    private let server: HeadlessMCPServer
    private let writer: HeadlessStdoutWriter

    init(server: HeadlessMCPServer, writer: HeadlessStdoutWriter) {
        self.server = server
        self.writer = writer
    }

    func run() async throws {
        var buffer = Data()
        while true {
            let chunk = FileHandle.standardInput.readData(ofLength: 4096)
            if chunk.isEmpty {
                if !buffer.isEmpty {
                    _ = try await handleLine(buffer)
                }
                return
            }

            buffer.append(chunk)
            while let newlineRange = buffer.firstRange(of: Data([0x0A])) {
                let line = Data(buffer[..<newlineRange.lowerBound])
                buffer.removeSubrange(..<newlineRange.upperBound)
                if try await handleLine(line) {
                    return
                }
            }
        }
    }

    private func handleLine(_ rawLine: Data) async throws -> Bool {
        let line = normalizedLine(rawLine)
        guard !line.isEmpty else {
            return false
        }
        let action = server.handle(frame: line)
        if let responseData = action.responseData {
            await writer.write(responseData)
        }
        return action.shouldExit
    }

    private func normalizedLine(_ rawLine: Data) -> Data {
        guard rawLine.last == 0x0D else {
            return rawLine
        }
        return rawLine.dropLast()
    }
}
