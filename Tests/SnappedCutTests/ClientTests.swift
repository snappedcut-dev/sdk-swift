import XCTest
@testable import SnappedCut

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A transport that records what it was asked and answers from a script.
final class Stub: Transport, @unchecked Sendable {
    struct Reply { let status: Int; let body: String }
    private(set) var calls: [URLRequest] = []
    private var queue: [Reply]
    private let throwOnce: Bool

    init(_ replies: [Reply], throwOnce: Bool = false) {
        self.queue = replies
        self.throwOnce = throwOnce
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls.append(request)
        if throwOnce && calls.count == 1 {
            throw URLError(.notConnectedToInternet)
        }
        guard !queue.isEmpty else {
            XCTFail("unexpected request: \(request.url?.absoluteString ?? "?")")
            return (Data(), 500)
        }
        let next = queue.removeFirst()
        return (Data(next.body.utf8), next.status)
    }
}

private func ok(_ body: String) -> Stub.Reply { .init(status: 200, body: body) }
private func fail(_ status: Int, _ body: String) -> Stub.Reply { .init(status: status, body: body) }

private let queuedJSON = """
{"job":{"id":"j1","kind":"cloud-render","state":"queued","seconds":4},
 "charged":8,"credits":92,"priced":{"seconds":4,"project":"p","layers":2}}
"""

private func jobJSON(_ state: String, _ error: String? = nil) -> String {
    let errorPart = error.map { "\"\($0)\"" } ?? "null"
    return """
    {"id":"j1","kind":"cloud-render","state":"\(state)","error":\(errorPart),"seconds":4}
    """
}

final class ClientTests: XCTestCase {
    private func client(_ replies: [Stub.Reply], chunkSize: Int = SnappedCut.chunk,
                        base: String = SnappedCut.defaultBase) -> (SnappedCut, Stub) {
        let stub = Stub(replies)
        return (SnappedCut(key: "sk_snapcut_test", base: base,
                           chunkSize: chunkSize, transport: stub), stub)
    }

    func testKeyIsSentAsABearerToken() async throws {
        let (snapcut, stub) = client([ok(#"{"id":"a","email":"e@x.com","credits":50}"#)])
        let account = try await snapcut.account()

        XCTAssertEqual(account.email, "e@x.com")
        XCTAssertEqual(stub.calls[0].value(forHTTPHeaderField: "authorization"),
                       "Bearer sk_snapcut_test")
        XCTAssertEqual(stub.calls[0].url?.absoluteString,
                       "https://snappedcut.com/api/account")
    }

    func testDescriptionNeverContainsTheKey() {
        // A description ends up in logs and crash reports.
        XCTAssertFalse(SnappedCut(key: "sk_snapcut_secret").description.contains("sk_snapcut_secret"))
    }

    func testATrailingSlashOnTheBaseDoesNotDoubleUp() async throws {
        let (snapcut, stub) = client([ok("{}")], base: "http://localhost:3000/")
        _ = try await snapcut.account()
        XCTAssertEqual(stub.calls[0].url?.absoluteString, "http://localhost:3000/api/account")
    }

    func testA402IsMatchableWithoutParsingAMessage() async throws {
        let (snapcut, _) = client([fail(402, #"{"error":"Not enough credits."}"#)])
        do {
            _ = try await snapcut.account()
            XCTFail("expected a refusal")
        } catch let error as SnappedCutError {
            XCTAssertTrue(error.outOfCredits)
            XCTAssertEqual(error.status, 402)
        }
    }

    func testA429ReportsItselfAsRateLimited() async throws {
        let (snapcut, _) = client([fail(429, #"{"error":"Slow down.","retryAfterMs":2000}"#)])
        do {
            _ = try await snapcut.account()
            XCTFail("expected a refusal")
        } catch let error as SnappedCutError {
            XCTAssertTrue(error.rateLimited)
            XCTAssertEqual(error.retryAfterMs, 2000)
        }
    }

    func testANonJSONErrorBodyStillThrowsCleanly() async throws {
        let (snapcut, _) = client([fail(500, "<html>oops")])
        do {
            _ = try await snapcut.account()
            XCTFail("expected a refusal")
        } catch let error as SnappedCutError {
            XCTAssertEqual(error.status, 500)
        }
    }

    func testAnUnreachableServerIsStatusZero() async throws {
        let stub = Stub([], throwOnce: true)
        let snapcut = SnappedCut(key: "k", transport: stub)
        do {
            _ = try await snapcut.account()
            XCTFail("expected a refusal")
        } catch let error as SnappedCutError {
            XCTAssertTrue(error.unreachable)
        }
    }

    func testRenderNeverSendsADuration() async throws {
        let (snapcut, stub) = client([ok(queuedJSON)])
        let queued = try await snapcut.render(Data(repeating: 0, count: 32))

        XCTAssertEqual(queued.charged, 8)
        XCTAssertEqual(queued.priced.seconds, 4)
        // A caller-supplied duration would be a caller-supplied price.
        XCTAssertFalse(stub.calls[0].url?.query?.contains("seconds") ?? true)
    }

    func testASmallBundleIsOneRequest() async throws {
        let (snapcut, stub) = client([ok(queuedJSON)])
        _ = try await snapcut.render(Data(repeating: 0, count: 1024))
        XCTAssertEqual(stub.calls.count, 1)
    }

    func testALargeBundleIsChunkedAndTheLastChunkIsFinal() async throws {
        let (snapcut, stub) = client(
            [ok(#"{"upload":"u1","received":1024}"#), ok(queuedJSON)], chunkSize: 1024
        )
        _ = try await snapcut.render(Data(repeating: 0, count: 1040))

        XCTAssertEqual(stub.calls.count, 2)
        let second = stub.calls[1].url?.query ?? ""
        XCTAssertTrue(second.contains("upload=u1"), second)
        XCTAssertTrue(second.contains("final=1"), second)
    }

    func testA409ResumesFromTheOffsetTheServerReports() async throws {
        // Our count and the server's disagreed. The server has the file.
        let (snapcut, stub) = client([
            ok(#"{"upload":"u1","received":10}"#),
            fail(409, #"{"error":"offset","expected":1024}"#),
            ok(queuedJSON)
        ], chunkSize: 1024)
        _ = try await snapcut.render(Data(repeating: 0, count: 1040))

        XCTAssertTrue(stub.calls[2].url?.query?.contains("offset=1024") ?? false)
    }

    func testARefusalMidUploadStopsRatherThanRetrying() async throws {
        let (snapcut, stub) = client([
            ok(#"{"upload":"u1","received":10}"#),
            fail(402, #"{"error":"Not enough credits."}"#)
        ], chunkSize: 1024)
        do {
            _ = try await snapcut.render(Data(repeating: 0, count: 1040))
            XCTFail("expected a refusal")
        } catch let error as SnappedCutError {
            XCTAssertTrue(error.outOfCredits)
            XCTAssertEqual(stub.calls.count, 2)
        }
    }

    func testWaitPollsUntilDoneThenReturnsTheBytes() async throws {
        let (snapcut, _) = client([
            ok(jobJSON("running")), ok(jobJSON("done")), ok("MOVIE")
        ])
        let seen = Seen()
        let file = try await snapcut.wait("j1", onState: { seen.add($0.state.rawValue) },
                                         sleeper: { _ in })

        XCTAssertEqual(seen.states, ["running", "done"])
        XCTAssertEqual(String(decoding: file, as: UTF8.self), "MOVIE")
    }

    func testAFailedJobThrowsRatherThanReturningAnEmptyFile() async throws {
        let (snapcut, _) = client([ok(jobJSON("failed", "decode failed"))])
        do {
            _ = try await snapcut.wait("j1", sleeper: { _ in })
            XCTFail("expected a failure")
        } catch let error as SnappedCutError {
            XCTAssertEqual(error.message, "decode failed")
        }
    }

    func testWaitGivesUpAtTheTimeoutWithA504() async throws {
        let (snapcut, _) = client(Array(repeating: ok(jobJSON("queued")), count: 20))
        do {
            _ = try await snapcut.wait("j1", timeout: -1, sleeper: { _ in })
            XCTFail("expected a timeout")
        } catch let error as SnappedCutError {
            XCTAssertEqual(error.status, 504)
        }
    }

    func testAnUnknownStateDecodesRatherThanFailing() throws {
        // A client that cannot parse a job it could still poll is worse than one
        // that treats a newer server's state as queued.
        let job = try JSONDecoder().decode(Job.self, from: Data(jobJSON("transcoding").utf8))
        XCTAssertEqual(job.state, .queued)
    }

    func testAJobIDIsEscapedIntoThePath() async throws {
        let (snapcut, stub) = client([ok(jobJSON("done"))])
        _ = try await snapcut.job("a/../b")
        let path = stub.calls[0].url?.absoluteString ?? ""
        XCTAssertFalse(path.contains("/../"), path)
    }

    func testJobsUnwrapsTheEnvelope() async throws {
        let (snapcut, _) = client([ok("{\"jobs\":[\(jobJSON("done")),\(jobJSON("queued"))]}")])
        let jobs = try await snapcut.jobs()
        XCTAssertEqual(jobs.map(\.state), [.done, .queued])
    }

    func testJobsToleratesAnEmptyAccount() async throws {
        let (snapcut, _) = client([ok("{}")])
        let jobs = try await snapcut.jobs()
        XCTAssertEqual(jobs.count, 0)
    }

    func testAMissingPricedStillDecodesTheJob() throws {
        // Every field defaults: a missing key should not fail the decode of a
        // job that exists.
        let body = try JSONDecoder().decode(
            QueuedBody.self, from: Data(#"{"job":{"id":"j1"}}"#.utf8)
        )
        XCTAssertEqual(body.job.id, "j1")
        XCTAssertEqual(body.priced.seconds, 0)
        XCTAssertEqual(body.job.kind, "cloud-render")
    }
}

/// A tiny box, because `onState` is @Sendable and cannot capture a var.
final class Seen: @unchecked Sendable {
    private(set) var states: [String] = []
    func add(_ state: String) { states.append(state) }
}
