import XCTest
@testable import VoiceFlow

final class SpeechModelCatalogTests: XCTestCase {
    func testExplicitTinyWinsOverHardware() {
        XCTAssertEqual(
            SpeechModelCatalog.whisperKitVariant(settingsName: "tiny.en", hardwareName: "medium.en"),
            "tiny.en"
        )
    }

    func testLegacyGgmlBaseBecomesSmall() {
        XCTAssertEqual(
            SpeechModelCatalog.whisperKitVariant(settingsName: "ggml-base.en", hardwareName: "medium.en"),
            "small.en"
        )
    }

    func testLowMemoryHardwareSelectsTinyWhenSettingsAreGeneric() {
        XCTAssertEqual(
            SpeechModelCatalog.whisperKitVariant(settingsName: "ggml-base.en", hardwareName: "tiny.en"),
            "tiny.en"
        )
    }

    func testGgmlFallbackNames() {
        XCTAssertEqual(SpeechModelCatalog.ggmlName(for: "tiny.en"), "ggml-tiny.en")
        XCTAssertEqual(SpeechModelCatalog.ggmlName(for: "small.en"), "ggml-small.en")
        XCTAssertEqual(SpeechModelCatalog.ggmlName(for: "small"), "ggml-small")
    }

    func testMultilingualNameStaysMultilingual() {
        XCTAssertEqual(
            SpeechModelCatalog.whisperKitVariant(settingsName: "small", hardwareName: "tiny.en"),
            "small"
        )
        XCTAssertFalse(SpeechModelCatalog.isEnglishOnly("small"))
    }

    func testEnglishModelForcesEnglish() {
        let choice = SpeechModelCatalog.modelChoice("tiny.en", keeping: "ja")
        XCTAssertEqual(choice.model, "tiny.en")
        XCTAssertEqual(choice.language, "en")
    }

    func testOtherLanguageSwitchesToMultilingual() {
        let choice = SpeechModelCatalog.languageChoice("es", keeping: "small.en")
        XCTAssertEqual(choice.model, "small")
        XCTAssertEqual(choice.language, "es")
    }

    func testAutoDetectSwitchesToMultilingual() {
        let choice = SpeechModelCatalog.languageChoice("auto", keeping: "tiny.en")
        XCTAssertEqual(choice.model, "small")
        XCTAssertEqual(choice.language, "auto")
    }
}
