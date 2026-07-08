import XCTest
@testable import Molten

final class MoltenWordCountTests: XCTestCase {
    func testMixedChineseEnglishCounting() {
        // 6 CJK chars + 2 latin words
        XCTAssertEqual(MoltenWordCount.count("熔字编辑器好 hello world"), 8)
    }

    func testPureEnglishCountsWords() {
        XCTAssertEqual(MoltenWordCount.count("one two  three\nfour-five"), 5)
    }

    func testPureCJKCountsCharacters() {
        XCTAssertEqual(MoltenWordCount.count("这是五个字"), 5)
    }

    func testPunctuationAndMarkupIgnored() {
        XCTAssertEqual(MoltenWordCount.count("# *bold*!"), 1)
        XCTAssertEqual(MoltenWordCount.count(""), 0)
        XCTAssertEqual(MoltenWordCount.count("——…!?。"), 0)
    }

    func testAccentedLatinStaysOneWord() {
        XCTAssertEqual(MoltenWordCount.count("café naïve"), 2)
    }
}
