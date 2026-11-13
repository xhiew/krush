public enum ParsedFrame: Equatable, Sendable {
    case request(FileRequest)
    case response(FileResponse)
    case debug(DebugFrame)
    case unrelated
}
