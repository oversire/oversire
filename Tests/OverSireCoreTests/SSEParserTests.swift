import XCTest
@testable import OverSireCore

final class SSEParserTests: XCTestCase {
    static let anthropic = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":12,"output_tokens":1}}}

    event: ping
    data: {"type": "ping"}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Héllo ✦"}}

    event: message_stop
    data: {"type":"message_stop"}


    """

    static let openai = """
    data: {"choices":[{"index":0,"delta":{"content":"Hi"}}]}

    : keep-alive

    data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":1}}

    data: [DONE]


    """

    func parse(_ text: String, chunks: Int? = nil, seed: UInt64 = 7) -> [SSEEvent] {
        var p = SSEParser()
        var out: [SSEEvent] = []
        let data = Data(text.utf8)
        if let max = chunks {
            var i = 0
            var s = seed
            while i < data.count {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                let n = Int(s >> 33) % max + 1
                out += p.feed(data[i..<min(i + n, data.count)])
                i += n
            }
        } else {
            out += p.feed(data)
        }
        return out + p.finish()
    }

    func testAnthropicEvents() {
        let e = parse(Self.anthropic)
        XCTAssertEqual(e.map(\.event), ["message_start", "ping", "content_block_delta", "message_stop"])
        XCTAssertTrue(e[2].data.contains("Héllo ✦"))
    }

    func testOpenAIEventsAndComments() {
        let e = parse(Self.openai)
        XCTAssertEqual(e.map(\.event), ["message", "message", "message"])
        XCTAssertEqual(e.last?.data, "[DONE]")
    }

    func testChunkEdgesGiveTheSameEvents() {
        for seed in UInt64(1)...40 {
            XCTAssertEqual(parse(Self.anthropic, chunks: 5, seed: seed), parse(Self.anthropic), "seed \(seed)")
            XCTAssertEqual(parse(Self.openai, chunks: 3, seed: seed), parse(Self.openai), "seed \(seed)")
        }
    }

    func testCRLFAndMultiLineData() {
        let e = parse("event: a\r\ndata: one\r\ndata: two\r\nid: 9\r\n\r\ndata:three\r\r")
        XCTAssertEqual(e, [SSEEvent(event: "a", data: "one\ntwo", id: "9"), SSEEvent(data: "three", id: "9")])
        // A CR at the end of one chunk and the LF at the start of the next is one line end.
        var p = SSEParser()
        XCTAssertEqual(p.feed(Data("data: x\r".utf8)), [])
        XCTAssertEqual(p.feed(Data("\n\r\n".utf8)), [SSEEvent(data: "x")])
    }

    func testStreamThatEndsWithoutABlankLine() {
        XCTAssertEqual(parse("data: {\"a\":1}\n\ndata: {\"b\":2}"), [SSEEvent(data: "{\"a\":1}"), SSEEvent(data: "{\"b\":2}")])
        XCTAssertEqual(parse("data: last\n"), [SSEEvent(data: "last")])
        XCTAssertEqual(parse(": only a comment\n"), [])
    }

    func testEventsOfAByteStream() async throws {
        let bytes = AsyncThrowingStream<Data, Error> { c in
            for ch in Self.openai.utf8 { c.yield(Data([ch])) }
            c.finish()
        }
        var got: [SSEEvent] = []
        for try await e in SSEParser.events(bytes) { got.append(e) }
        XCTAssertEqual(got.count, 3)
    }
}
