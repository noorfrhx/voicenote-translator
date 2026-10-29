import XCTest
@testable import VNTCore

final class FramingTests: XCTestCase {
    func testRoundTrip() throws {
        let data = try XCTUnwrap(Framing.encode(["type": "hello", "id": "1"]))
        var decoder = FrameDecoder()
        let messages = try decoder.append(data)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["type"] as? String, "hello")
    }

    func testSplitAcrossReads() throws {
        let a = try XCTUnwrap(Framing.encode(["n": 1]))
        let b = try XCTUnwrap(Framing.encode(["n": 2]))
        let stream = a + b
        var decoder = FrameDecoder()
        var got: [[String: Any]] = []
        for byte in stream { got += try decoder.append(Data([byte])) }
        XCTAssertEqual(got.map { $0["n"] as? Int }, [1, 2])
    }

    func testRejectsHugeLength() {
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0xFF, 0xFF, 0xFF, 0xFF])))
    }
}
