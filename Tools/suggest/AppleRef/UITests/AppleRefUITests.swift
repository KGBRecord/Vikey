import XCTest

/// Reads Apple's suggestion bar for every case (Tools/suggest/README.md): the app puts the case's text before
/// the cursor, this test taps the case's letters on the keyboard (key centres, like a perfect typist) and
/// prints the bar as `SUGGEST\t{"id", "cells": [[label, selected]...]}`, cells left to right.
/// Environment (xcodebuild passes TEST_RUNNER_<name>): CASES = the cases file (a host path).
final class AppleRefUITests: XCTestCase {
    func testSuggestionBar() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CASES"] = ProcessInfo.processInfo.environment["CASES"]
        app.launch()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        let intro = app.buttons["Continue"]   // the first keyboard's slide-to-type introduction
        if intro.waitForExistence(timeout: 2) { intro.tap() }
        // key centres, once: lowercase letters (a capital is the same key)
        var keys: [Character: CGPoint] = [:]
        for k in app.keyboards.firstMatch.keys.allElementsBoundByIndex where k.label.count == 1 && k.label.first!.isLetter {
            keys[Character(k.label.lowercased())] = CGPoint(x: k.frame.midX, y: k.frame.midY)
        }
        XCTAssertEqual(keys.count, 26, "\(keys.keys.sorted())")
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let bar = app.otherElements["Typing Predictions"]
        let label = app.staticTexts["letters"]
        func cells() -> [[Any]] {
            bar.descendants(matching: .other).allElementsBoundByIndex
                .filter { !$0.label.isEmpty && $0.frame.height > 0 }
                .sorted { $0.frame.minX < $1.frame.minX }
                .map { [$0.label, $0.isSelected] }
        }
        func same(_ a: [[Any]], _ b: [[Any]]) -> Bool { a.map { "\($0)" } == b.map { "\($0)" } }
        while true {
            app.buttons["next"].tap()
            let parts = label.label.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if parts.first == "done" || parts.count < 2 { break }
            let before = cells()
            for ch in parts[1] { if let p = keys[ch] { origin.withOffset(CGVector(dx: p.x, dy: p.y)).tap() } }
            // the bar settles a moment after the last key: wait for a change (when letters were typed), then two equal reads
            var now = cells(), last: [[Any]] = []
            let end = Date().addingTimeInterval(2)
            while Date() < end {
                if !(parts[1].isEmpty == false && same(now, before)) && same(now, last) { break }
                last = now; usleep(120_000); now = cells()
            }
            let line = try JSONSerialization.data(withJSONObject: ["id": parts[0], "cells": now])
            print("SUGGEST\t" + String(decoding: line, as: UTF8.self))
        }
    }
}
