import Testing
@testable import KRWire

struct KRWireSmokeTests {
    @Test func moduleIsImportable() {
        _ = KRWire.self
    }
}
