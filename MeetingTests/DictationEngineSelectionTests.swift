import XCTest
@testable import Meeting

final class DictationEngineSelectionTests: XCTestCase {
    private func config(engine: DictationEngine, key: String) -> DictationProviderConfig {
        DictationProviderConfig(
            engine: engine, geminiKey: key,
            geminiModel: "gemini-2.5-pro", glossary: "",
            localModel: "large-v3-turbo"
        )
    }

    func test_geminiSelected_withKey_usesGemini() {
        let r = DictationProviderFactory.make(config: config(engine: .gemini, key: "abc"))
        XCTAssertFalse(r.engineDidFallBack)
        XCTAssertTrue(r.provider is GeminiProvider)
    }

    func test_geminiSelected_noKey_fallsBackToLocal() {
        let r = DictationProviderFactory.make(config: config(engine: .gemini, key: ""))
        XCTAssertTrue(r.engineDidFallBack)
        XCTAssertTrue(r.provider is LocalProvider)
    }

    func test_localSelected_usesLocal() {
        let r = DictationProviderFactory.make(config: config(engine: .local, key: "abc"))
        XCTAssertFalse(r.engineDidFallBack)
        XCTAssertTrue(r.provider is LocalProvider)
    }
}
