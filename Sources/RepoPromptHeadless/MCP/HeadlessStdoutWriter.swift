import Foundation

actor HeadlessStdoutWriter {
    func write(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
