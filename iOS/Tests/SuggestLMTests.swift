import XCTest
import UIKit

/// The English suggestion model (SuggestLM, SuggestEN.bin) and what the bar does with it.
final class SuggestLMTests: XCTestCase {
    private let lm = SuggestLM.shared
    private let sender = KeyboardView()

    func testLoads() {   // a file this code can't read would silently leave the old suggestions
        XCTAssertGreaterThan(lm.wordCount, 50_000)
        XCTAssertNotNil(lm.nn)
    }

    func testNetworkReadsOnAndStartsOver() {
        let nn = lm.nn!
        func top(_ before: String) -> String? {
            guard let p = nn.next(after: before) else { return nil }
            let k = (4..<nn.V).max { p[$0] < p[$1] }!
            return (0..<lm.wordCount).first { nn.networkId($0) == k }.map(lm.form)
        }
        XCTAssertEqual(top("Thank "), "you")
        XCTAssertEqual(top("Thank you so "), "much")   // read on from "Thank "
        XCTAssertEqual(top("Thank you so "), "much")   // the same text: the same answer
        XCTAssertEqual(top("I am going to the "), top("I am going to the "))
        let p = nn.next(after: "See you ")!
        var sum: Float = 0
        for k in 0..<nn.V { sum += p[k] }
        XCTAssertEqual(sum, 1, accuracy: 0.001)
    }

    func testCompletionsFollowTheContext() {
        XCTAssertEqual(lm.completions("peop", before: "For a lot of ", limit: 1), ["people"])
        XCTAssertEqual(lm.completions("o", before: "it depends ", limit: 1), ["on"])
        XCTAssertEqual(lm.completions("o", before: "I'm tired ", limit: 1), ["of"])
    }

    func testDisplayForms() {
        XCTAssertEqual(lm.completions("youtu", before: "on ", limit: 1), ["YouTube"])
        XCTAssertTrue(lm.completions("don", before: "I ", limit: 3).contains("don't"))
    }

    func testNextWords() {
        let next = lm.nextWords(before: "I ", limit: 3).map { $0.lowercased() }
        XCTAssertTrue(next.contains("have") || next.contains("don't"), "\(next)")
        XCTAssertEqual(lm.nextWords(before: "thank ", limit: 1), ["you"])
    }

    func testAWordOnItsWayIsNotATypo() {
        XCTAssertTrue(lm.prefersFinishing("resi", over: "res", before: "I want to "))
        XCTAssertTrue(lm.prefersFinishing("helpi", over: "help", before: "I'm happy "))
        XCTAssertFalse(lm.prefersFinishing("teh", over: "the", before: "I saw "))
    }

    // the bar (Tony's screenshot: "Resi" showed "Res" and "Reis", and space would have made it "Res")
    private func bar(after text: String, typing: String) -> [Suggestion] {
        let p = CursorProxy()
        p.text = text; p.cursor = text.count
        let vc = KeyboardViewController()
        vc.proxy = p
        vc.loadViewIfNeeded()
        vc.view.frame = CGRect(x: 0, y: 0, width: 402, height: 300)
        vc.view.layoutIfNeeded()
        vc.viewWillAppear(false)
        vc.setLanguageForTests(0)
        for ch in typing { vc.keyboard(sender, didTap: .char(String(ch))) }
        vc.updateSuggestions()
        return vc.keyboardViewForTests.suggestions
    }

    func testResiFinishesTheWord() {
        let cells = bar(after: "", typing: "resi")
        XCTAssertEqual(cells.first?.text, "Resi")
        XCTAssertTrue(cells.dropFirst().allSatisfy { $0.text.hasPrefix("Resi") }, "\(cells.map(\.text))")
        XCTAssertFalse(cells.contains { $0.highlighted }, "space keeps what was typed")
    }

    func testCapitalIShows() {   // the system keyboard shows "I" for a typed "i", and space puts it in
        let cells = bar(after: "and then ", typing: "i")
        XCTAssertTrue(cells.contains { $0.text == "I" && $0.highlighted }, "\(cells.map(\.text))")
    }

    func testTypoStillFixed() {
        let cells = bar(after: "I saw ", typing: "teh")
        XCTAssertTrue(cells.contains { $0.text == "the" && $0.highlighted }, "\(cells.map(\.text))")
    }
}
