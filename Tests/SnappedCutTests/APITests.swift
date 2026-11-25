import XCTest
@testable import SnappedCut

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private func reply(_ status: Int, _ body: String) -> Stub.Reply { .init(status: status, body: body) }

private let job = #"{"id":"job_1","kind":"cloud-render","state":"queued","error":null,"seconds":4,"createdAt":1,"updatedAt":1,"somethingNew":true}"#

final class APITests: XCTestCase {
    private func client(_ replies: [Stub.Reply]) -> (SnappedCut, Stub) {
        let stub = Stub(replies)
        return (SnappedCut(key: "sk_snapcut_test", base: "https://example.test", transport: stub), stub)
    }

    func testTheWebhookVector() {
        let secret = "whsec_snapcut_test"
        let body = #"{"id":"evt_1","type":"job.succeeded"}"#
        let header = "t=1760000000000,v1=54c2adf2a351242de19b156794d65c56bebf9fc56cadac990c56b979a7a61ab2"
        XCTAssertTrue(SnappedCut.verifyWebhook(secret: secret, rawBody: body, signatureHeader: header,
                                               nowMs: 1_760_000_001_000))
        XCTAssertFalse(SnappedCut.verifyWebhook(secret: secret, rawBody: body, signatureHeader: header,
                                                nowMs: 1_760_000_400_000))
        XCTAssertFalse(SnappedCut.verifyWebhook(secret: secret, rawBody: body + " ", signatureHeader: header,
                                                nowMs: 1_760_000_001_000))
        XCTAssertFalse(SnappedCut.verifyWebhook(secret: secret, rawBody: body, signatureHeader: nil,
                                                nowMs: 1_760_000_001_000))
    }

    func testTheHandRolledSHA256MatchesTheStandard() {
        // FIPS 180-2's "abc", and a message long enough to need a second block.
        let hex = { (bytes: [UInt8]) in bytes.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(sha256(Array("abc".utf8))),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex(sha256(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testCreateJobSendsTheIdempotencyKeyTheBearerAndJSON() async throws {
        let (snapcut, stub) = client([
            reply(201, #"{"job":\#(job),"charged":4,"price":1,"credits":96,"idempotent":false}"#)
        ])
        let created = try await snapcut.createJob(["design": ["clips": []], "format": "mp4"],
                                                  idempotencyKey: "idem-1")
        XCTAssertEqual(created.job.id, "job_1")
        XCTAssertEqual(created.charged, 4)
        XCTAssertEqual(created.credits, 96)

        let request = stub.calls[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/api/jobs")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "idem-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk_snapcut_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "snappedcut-swift/0.2.0")
        let sent = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
        XCTAssertEqual(sent["format"], "mp4")
        XCTAssertEqual(sent["design"]?["clips"], [])
    }

    func testA402IsTheSDKErrorWithIsOutOfCredits() async {
        let (snapcut, _) = client([reply(402, #"{"error":"Not enough credits.","retryAfterMs":0,"code":"credits"}"#)])
        do {
            _ = try await snapcut.createJob(["bundle": "asset_1"])
            XCTFail("expected a refusal")
        } catch let error as SnappedCutError {
            XCTAssertEqual(error.status, 402)
            XCTAssertEqual(error.message, "Not enough credits.")
            XCTAssertEqual(error.retryAfterMs, 0)
            XCTAssertEqual(error.code, "credits")
            XCTAssertTrue(error.isOutOfCredits)
            XCTAssertFalse(error.isRateLimited)
        } catch { XCTFail("wrong error \(error)") }
    }

    func testUploadPutsTwoChunksWithoutTheKeyThenConfirms() async throws {
        let (snapcut, stub) = client([
            reply(201, #"{"assetId":"asset_1","upload":{"method":"PUT","url":"https://up.test/api/uploads/asset_1?token=abc","maxChunkBytes":6}}"#),
            reply(200, "{}"), reply(200, "{}"),
            reply(200, #"{"asset":{"id":"asset_1","name":"clip.webm","contentType":"video/webm","bytes":10,"confirmed":true}}"#),
        ])
        let asset = try await snapcut.upload(Data("0123456789".utf8), contentType: "video/webm", name: "clip.webm")
        XCTAssertEqual(asset.id, "asset_1")
        XCTAssertTrue(asset.confirmed)

        XCTAssertEqual(stub.calls.count, 4)
        let puts = Array(stub.calls[1...2])
        XCTAssertEqual(puts.map { $0.url?.absoluteString ?? "" }, [
            "https://up.test/api/uploads/asset_1?token=abc&offset=0",
            "https://up.test/api/uploads/asset_1?token=abc&offset=6",
        ])
        XCTAssertEqual(puts.map { $0.httpBody ?? Data() }, [Data("012345".utf8), Data("6789".utf8)])
        for put in puts {
            XCTAssertEqual(put.httpMethod, "PUT")
            XCTAssertNil(put.value(forHTTPHeaderField: "Authorization"))
        }
        XCTAssertEqual(stub.calls[3].url?.absoluteString, "https://example.test/api/uploads/asset_1/confirm")
        XCTAssertEqual(stub.calls[3].httpMethod, "POST")
    }

    func testUploadingAFileReadsTheSameChunks() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("snappedcut-\(UUID()).bin")
        try Data("0123456789".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let (snapcut, stub) = client([
            reply(201, #"{"assetId":"a","upload":{"url":"https://up.test/u?token=x","maxChunkBytes":6}}"#),
            reply(200, "{}"), reply(200, "{}"),
            reply(200, #"{"asset":{"id":"a","contentType":"video/webm","confirmed":true}}"#),
        ])
        _ = try await snapcut.upload(file: file, contentType: "video/webm")
        XCTAssertEqual(stub.calls[1...2].map { $0.httpBody ?? Data() },
                       [Data("012345".utf8), Data("6789".utf8)])
    }

    func testWaitForJobReturnsTheJobOnDone() async throws {
        let done = job.replacingOccurrences(of: #""queued""#, with: #""done""#)
            .replacingOccurrences(of: #""somethingNew":true"#,
                                  with: #""outputs":[{"index":0,"key":null,"format":"mp4","bytes":9,"url":"/x"}]"#)
        let (snapcut, stub) = client([
            reply(200, job),
            reply(200, job.replacingOccurrences(of: #""queued""#, with: #""running""#)),
            reply(200, done),
        ])
        let finished = try await snapcut.waitForJob("job_1", sleeper: { _ in })
        XCTAssertTrue(finished.isDone)
        XCTAssertEqual(finished.outputs?.first?.format, "mp4")
        XCTAssertEqual(stub.calls.count, 3)
    }

    func testWaitForJobThrowsTheJobsErrorOnFailed() async {
        let failed = job.replacingOccurrences(of: #""queued","error":null"#,
                                              with: #""failed","error":"Decode failed.""#)
        let (snapcut, _) = client([reply(200, job), reply(200, failed)])
        do {
            _ = try await snapcut.waitForJob("job_1", sleeper: { _ in })
            XCTFail("expected a failure")
        } catch let error as SnappedCutError {
            XCTAssertEqual(error.message, "Decode failed.")
        } catch { XCTFail("wrong error \(error)") }
    }

    func testADestinationTest422IsAnAnswer() async throws {
        let (snapcut, _) = client([reply(422, #"{"ok":false,"key":"k","error":"Access denied"}"#)])
        let answer = try await snapcut.testDestination("dst_1")
        XCTAssertEqual(answer["ok"], false)
    }

    func testDownloadOutputAsksForAnIndexOnlyPastTheFirst() async throws {
        let (snapcut, stub) = client([reply(200, "abc"), reply(200, "def")])
        _ = try await snapcut.downloadOutput("job_1")
        let second = try await snapcut.downloadOutput("job_1", index: 1)
        XCTAssertEqual(second, Data("def".utf8))
        XCTAssertEqual(stub.calls.map { $0.url?.absoluteString ?? "" }, [
            "https://example.test/api/jobs/job_1/output",
            "https://example.test/api/jobs/job_1/output?index=1",
        ])
    }

    func testUsageOmitsAbsentParameters() async throws {
        let (snapcut, stub) = client([reply(200, "{}"), reply(200, "{}")])
        _ = try await snapcut.usage()
        _ = try await snapcut.usage(endUserId: "u 1", groupBy: "operation")
        XCTAssertEqual(stub.calls[0].url?.absoluteString, "https://example.test/api/usage")
        XCTAssertEqual(stub.calls[1].url?.absoluteString,
                       "https://example.test/api/usage?endUserId=u%201&groupBy=operation")
    }
}
