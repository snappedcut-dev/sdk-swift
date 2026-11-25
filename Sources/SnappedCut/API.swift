import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The API beyond the bundle queue: JSON jobs, batches, designs, uploads,
/// usage, embed tokens, storage destinations and webhook endpoints. The same
/// method set as every other Snapped Cut SDK.
extension SnappedCut {
    // MARK: - Plumbing

    func send(_ method: String, _ path: String, json: JSONValue? = nil,
              headers: [String: String] = [:], accept: Set<Int> = []) async throws -> Data {
        let body = try json.map { try JSONEncoder().encode($0) }
        return try await call(path, method: method, body: body,
                              contentType: json == nil ? nil : "application/json",
                              headers: headers, accept: accept)
    }

    // MARK: - Jobs

    /// Queue a job described as JSON (`design`, `bundle` asset id, `outputs`,
    /// `format`, `preset`, ...). With an Idempotency-Key, a retry answers with
    /// the first job rather than charging for a second.
    public func createJob(_ request: JSONObject, idempotencyKey: String? = nil) async throws -> Created {
        let key = idempotencyKey ?? request["idempotencyKey"]?.stringValue
        return try decode(Created.self, from: await send(
            "POST", "/api/jobs", json: .object(request),
            headers: key.map { ["Idempotency-Key": $0] } ?? [:]
        ))
    }

    /// Up to 100 jobs; `defaults` is merged under each. Each item is answered
    /// on its own, so one refusal does not sink the rest.
    public func createBatch(_ jobs: [JSONObject], defaults: JSONObject? = nil) async throws -> JSONValue {
        var body: JSONObject = ["jobs": .array(jobs.map { .object($0) })]
        if let defaults { body["defaults"] = .object(defaults) }
        return try decode(JSONValue.self, from: await send("POST", "/api/jobs/batch", json: .object(body)))
    }

    public func getJob(_ id: String) async throws -> Job { try await job(id) }

    public func listJobs() async throws -> [Job] { try await jobs() }

    /// One rendered file of a job. Throws unless the job is done.
    public func downloadOutput(_ id: String, index: Int = 0) async throws -> Data {
        try await call("/api/jobs/\(escape(id))/output" + (index > 0 ? "?index=\(index)" : ""))
    }

    // MARK: - Designs

    /// Compile a design to the editor's project without rendering it.
    public func compileDesign(_ design: JSONValue, vars: JSONObject? = nil) async throws -> JSONValue {
        var body: JSONObject = ["design": design]
        if let vars { body["vars"] = .object(vars) }
        return try decode(JSONValue.self, from: await send("POST", "/api/designs", json: .object(body)))
    }

    public func renderDesign(_ design: JSONValue, options: JSONObject = [:],
                             idempotencyKey: String? = nil) async throws -> Created {
        var request = options
        request["design"] = design
        return try await createJob(request, idempotencyKey: idempotencyKey)
    }

    // MARK: - Uploads

    /// Upload bytes once, for use by id in designs, tools and jobs.
    public func upload(_ data: Data, contentType: String, name: String? = nil) async throws -> Asset {
        try await upload(size: data.count, contentType: contentType, name: name) { from, to in
            data.subdata(in: (data.startIndex + from)..<(data.startIndex + to))
        }
    }

    /// Upload a file, reading one chunk at a time rather than the whole file.
    public func upload(file: URL, contentType: String, name: String? = nil) async throws -> Asset {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        return try await upload(size: size, contentType: contentType,
                                name: name ?? file.lastPathComponent) { from, to in
            try handle.seek(toOffset: UInt64(from))
            return try handle.read(upToCount: to - from) ?? Data()
        }
    }

    private func upload(size: Int, contentType: String, name: String?,
                        chunk: (Int, Int) throws -> Data) async throws -> Asset {
        var body: JSONObject = ["contentType": .string(contentType)]
        if let name { body["name"] = .string(name) }
        let made = try decode(UploadStart.self, from: await send("POST", "/api/uploads", json: .object(body)))
        let step = max(1, made.upload.maxChunkBytes ?? size)

        var offset = 0
        repeat {
            let to = min(size, offset + step)
            // The upload URL carries its own token; the key is not sent to it.
            _ = try await call("", method: "PUT", body: try chunk(offset, to), contentType: contentType,
                               elsewhere: "\(made.upload.url)&offset=\(offset)")
            offset = to
        } while offset < size

        return try decode(AssetBody.self, from: await send(
            "POST", "/api/uploads/\(escape(made.assetId))/confirm", json: [:]
        )).asset
    }

    public func getAsset(_ id: String) async throws -> Asset {
        try decode(AssetBody.self, from: await call("/api/uploads/\(escape(id))")).asset
    }

    public func deleteAsset(_ id: String) async throws {
        _ = try await call("/api/uploads/\(escape(id))", method: "DELETE")
    }

    // MARK: - Meta, usage, embed

    /// Every operation, its render parameters, and the presets.
    public func operations() async throws -> JSONValue {
        try decode(JSONValue.self, from: await call("/api/operations"))
    }

    /// Credits, jobs and seconds over a window. `groupBy`: period, endUserId,
    /// key or operation.
    public func usage(from: Int64? = nil, to: Int64? = nil, endUserId: String? = nil,
                      groupBy: String? = nil) async throws -> JSONValue {
        let query = [("from", from.map { String($0) }), ("to", to.map { String($0) }),
                     ("endUserId", endUserId), ("groupBy", groupBy)]
            .compactMap { name, value in value.map { "\(name)=\(escape($0))" } }
            .joined(separator: "&")
        return try decode(JSONValue.self, from: await call("/api/usage" + (query.isEmpty ? "" : "?\(query)")))
    }

    /// Delete one end user's renders and uploads, and their id from everything kept.
    public func deleteEndUser(_ endUserId: String) async throws -> JSONValue {
        try decode(JSONValue.self, from: await call("/api/usage?endUserId=\(escape(endUserId))",
                                                    method: "DELETE"))
    }

    /// Mint an embed session token for one of your end users. Server side only:
    /// it needs your secret key.
    public func createEmbedToken(pk: String, endUserId: String, maxCredits: Int? = nil,
                                 ttlSeconds: Int? = nil, origin: String? = nil,
                                 features: JSONObject? = nil) async throws -> JSONValue {
        var body: JSONObject = ["pk": .string(pk), "endUserId": .string(endUserId)]
        if let maxCredits { body["maxCredits"] = .number(Double(maxCredits)) }
        if let ttlSeconds { body["ttlSeconds"] = .number(Double(ttlSeconds)) }
        if let origin { body["origin"] = .string(origin) }
        if let features { body["features"] = .object(features) }
        return try decode(JSONValue.self, from: await send("POST", "/api/embed/tokens", json: .object(body)))
    }

    // MARK: - Storage destinations

    public func listDestinations() async throws -> [StorageDestination] {
        try decode(DestinationsBody.self, from: await call("/api/destinations")).destinations
    }

    /// `input`: name, endpoint, bucket, accessKeyId, secretAccessKey, and
    /// optionally region, prefix, pathStyle.
    public func createDestination(_ input: JSONObject) async throws -> StorageDestination {
        try decode(DestinationBody.self, from: await send("POST", "/api/destinations",
                                                          json: .object(input))).destination
    }

    public func getDestination(_ id: String) async throws -> StorageDestination {
        try decode(DestinationBody.self, from: await call("/api/destinations/\(escape(id))")).destination
    }

    public func updateDestination(_ id: String, _ patch: JSONObject) async throws -> StorageDestination {
        try decode(DestinationBody.self, from: await send("PATCH", "/api/destinations/\(escape(id))",
                                                          json: .object(patch))).destination
    }

    public func deleteDestination(_ id: String) async throws {
        _ = try await call("/api/destinations/\(escape(id))", method: "DELETE")
    }

    /// Write a test object. A failed write (422) is an answer `{ok: false, ...}`,
    /// not an error.
    public func testDestination(_ id: String) async throws -> JSONValue {
        try decode(JSONValue.self, from: await send("POST", "/api/destinations/\(escape(id))/test",
                                                    accept: [422]))
    }

    public func presignDestination(_ id: String, key: String, expiresIn: Int? = nil) async throws -> JSONValue {
        var body: JSONObject = ["key": .string(key)]
        if let expiresIn { body["expiresIn"] = .number(Double(expiresIn)) }
        return try decode(JSONValue.self, from: await send("POST", "/api/destinations/\(escape(id))/presign",
                                                           json: .object(body)))
    }

    // MARK: - Webhook endpoints

    public func listWebhooks() async throws -> [WebhookEndpoint] {
        try decode(WebhooksBody.self, from: await call("/api/webhooks")).webhooks
    }

    /// The secret comes back this once.
    public func createWebhook(url: String, events: [String]? = nil) async throws -> CreatedWebhook {
        var body: JSONObject = ["url": .string(url)]
        if let events { body["events"] = .array(events.map { .string($0) }) }
        return try decode(CreatedWebhook.self, from: await send("POST", "/api/webhooks", json: .object(body)))
    }

    public func getWebhook(_ id: String) async throws -> WebhookEndpoint {
        try decode(WebhookBody.self, from: await call("/api/webhooks/\(escape(id))")).webhook
    }

    public func updateWebhook(_ id: String, url: String? = nil, events: [String]? = nil,
                              enabled: Bool? = nil) async throws -> WebhookEndpoint {
        var body: JSONObject = [:]
        if let url { body["url"] = .string(url) }
        if let events { body["events"] = .array(events.map { .string($0) }) }
        if let enabled { body["enabled"] = .bool(enabled) }
        return try decode(WebhookBody.self, from: await send("PATCH", "/api/webhooks/\(escape(id))",
                                                             json: .object(body))).webhook
    }

    public func deleteWebhook(_ id: String) async throws {
        _ = try await call("/api/webhooks/\(escape(id))", method: "DELETE")
    }

    /// A new secret; the old one stops verifying.
    public func rotateWebhook(_ id: String) async throws -> String {
        try decode(SecretBody.self, from: await send("POST", "/api/webhooks/\(escape(id))/rotate",
                                                     json: [:])).secret
    }

    public func webhookDeliveries(_ id: String, limit: Int = 50) async throws -> [JSONValue] {
        try decode(DeliveriesBody.self,
                   from: await call("/api/webhooks/\(escape(id))/deliveries?limit=\(limit)")).deliveries
    }

    public func testWebhook(_ id: String) async throws -> JSONValue {
        try decode(JSONValue.self, from: await send("POST", "/api/webhooks/\(escape(id))/test", json: [:]))
    }
}
