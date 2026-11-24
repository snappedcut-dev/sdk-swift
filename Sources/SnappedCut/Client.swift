import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A transport, so tests need no server.
public protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

/// `@unchecked` because `URLSession` is not `Sendable` in corelibs-foundation,
/// though it is safe to use from multiple tasks. Marking it is the difference
/// between a warning on every Linux build and none.
struct URLSessionTransport: Transport, @unchecked Sendable {
    let session: URLSession

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        /* `session.data(for:)` does not exist in corelibs-foundation on Linux,
           only on Apple platforms — so this wraps `dataTask`, which exists on
           both, rather than carrying two code paths behind an #if. The CI's
           Linux job is what caught this. */
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                continuation.resume(returning: (data ?? Data(), status))
            }
            task.resume()
        }
    }
}

/// A client for the Snapped Cut cloud render API.
///
/// URLSession and Foundation, and nothing else -- no package dependencies, so
/// it adds nothing to an app that already links Foundation. The API is five
/// endpoints; a client for it should be readable in one sitting.
///
/// ```swift
/// let snapcut = SnappedCut()                       // reads SNAPCUT_KEY
/// let job = try await snapcut.render(bundle)
/// let file = try await snapcut.wait(job.id)
/// ```
///
/// This covers the server API: the cloud render queue and the account behind
/// it. The editing itself runs on Snapped Cut's machines, driven from the
/// editor or the embed -- not from here.
public struct SnappedCut: Sendable {
    public static let defaultBase = "https://snappedcut.com"

    /// How much of a bundle goes in one request.
    ///
    /// Cloudflare's free plan refuses a proxied request body over 100 MB and
    /// the site is behind it, so a 512 MB bundle cannot be one POST however
    /// well it streams. 64 MiB leaves room for headers and for a tighter cap on
    /// some other proxy without making the chunk count silly.
    public static let chunk = 64 * 1024 * 1024

    static let maxAttempts = 3

    let key: String
    let base: String
    let chunkSize: Int
    let transport: Transport

    public init(
        key: String? = nil,
        base: String = SnappedCut.defaultBase,
        timeout: TimeInterval = 120,
        chunkSize: Int = SnappedCut.chunk,
        transport: Transport? = nil
    ) {
        self.key = key ?? ProcessInfo.processInfo.environment["SNAPCUT_KEY"] ?? ""
        var trimmed = base
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.base = trimmed
        self.chunkSize = chunkSize

        if let transport {
            self.transport = transport
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            self.transport = URLSessionTransport(session: URLSession(configuration: configuration))
        }
    }

    // MARK: - Plumbing

    func call(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {
        guard let url = URL(string: base + path) else {
            throw SnappedCutError(message: "That is not a usable URL: \(base + path)", status: 0)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("snappedcut-swift/0.1.0", forHTTPHeaderField: "user-agent")
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "content-type")
        }
        request.httpBody = body

        let data: Data
        let status: Int
        do {
            (data, status) = try await transport.send(request)
        } catch {
            // Never reached the server, so worth sending again.
            throw SnappedCutError(
                message: "Could not reach Snapped Cut: \(error.localizedDescription)",
                status: 0
            )
        }

        guard status < 400 else {
            // An error body is not guaranteed to be JSON -- a proxy may answer
            // with HTML -- and the status is the part that matters either way.
            let detail = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw SnappedCutError(
                message: detail?.error ?? "Snapped Cut said \(status).",
                status: status,
                retryAfterMs: detail?.retryAfterMs ?? 0,
                expected: detail?.expected ?? 0
            )
        }
        return data
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SnappedCutError(message: "Snapped Cut sent something unreadable.", status: 0)
        }
    }

    // MARK: - The API

    /// The account behind the key: who, and how many credits are left.
    public func account() async throws -> Account {
        try decode(Account.self, from: await call("/api/account"))
    }

    /// Queue a render.
    ///
    /// There is no `seconds` parameter and there should not be: the server reads
    /// the timeline duration out of the bundle's own `project.json` and prices
    /// on that. A duration supplied by the caller is a price supplied by the
    /// caller. What it was charged for comes back in `priced`.
    ///
    /// A bundle over `chunkSize` is uploaded in pieces and resumes from the
    /// *server's* count of what it holds, not ours.
    public func render(_ bundle: Data, kind: String = "cloud-render") async throws -> QueuedJob {
        if bundle.count <= chunkSize {
            let query = "kind=\(escape(kind))"
            let body = try decode(
                QueuedBody.self,
                from: await call("/api/jobs?\(query)", method: "POST", body: bundle,
                                 contentType: "application/zip")
            )
            return QueuedJob(job: body.job, charged: body.charged,
                             credits: body.credits, priced: body.priced)
        }
        return try await renderChunked(bundle, kind: kind)
    }

    private func renderChunked(_ bundle: Data, kind: String) async throws -> QueuedJob {
        var upload = ""
        var offset = 0
        var attempts = 0

        while offset < bundle.count {
            let to = min(bundle.count, offset + chunkSize)
            let last = to == bundle.count

            var query = "kind=\(escape(kind))&offset=\(offset)"
            if !upload.isEmpty { query += "&upload=\(escape(upload))" }
            if last { query += "&final=1" }

            do {
                // `subdata` on a Data slice, so a chunk is not a copy of the
                // whole bundle.
                let piece = bundle.subdata(in: offset..<to)
                let data = try await call("/api/jobs?\(query)", method: "POST",
                                          body: piece, contentType: "application/zip")

                if last {
                    let body = try decode(QueuedBody.self, from: data)
                    return QueuedJob(job: body.job, charged: body.charged,
                                     credits: body.credits, priced: body.priced)
                }

                // The server's count, not ours: it is the one with the file.
                let chunk = try decode(ChunkBody.self, from: data)
                upload = chunk.upload
                offset = chunk.received
                attempts = 0
            } catch let error as SnappedCutError {
                attempts += 1
                if attempts > SnappedCut.maxAttempts { throw error }

                // Where the server says its copy ends. Believe it over our own.
                if error.status == 409 {
                    offset = error.expected
                    continue
                }
                // A refusal is a refusal -- no credits, bad bundle, bad key.
                // Only a lost connection (0) or a server fault is worth resending.
                if error.status != 0 && error.status < 500 { throw error }
            }
        }

        throw SnappedCutError(message: "That upload ended without queueing a job.", status: 0)
    }

    public func job(_ id: String) async throws -> Job {
        try decode(Job.self, from: await call("/api/jobs/\(escape(id))"))
    }

    public func jobs() async throws -> [Job] {
        try decode(JobsBody.self, from: await call("/api/jobs")).jobs
    }

    /// The rendered file. Throws unless the job is done.
    public func output(_ id: String) async throws -> Data {
        try await call("/api/jobs/\(escape(id))/output")
    }

    /// Wait for a job to finish, then hand back the file.
    ///
    /// Backs off rather than polling at a fixed interval: a render is minutes,
    /// so a one-second poll spends most of its requests learning nothing, and
    /// the server has a rate limit a busy loop will find.
    ///
    /// Honours task cancellation between polls.
    public func wait(
        _ id: String,
        timeout: TimeInterval = 1800,
        onState: (@Sendable (Job) -> Void)? = nil,
        sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil
    ) async throws -> Data {
        let rest = sleeper ?? { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        let deadline = Date().addingTimeInterval(timeout)
        var delay: TimeInterval = 1

        while true {
            let current = try await job(id)
            onState?(current)

            if current.isDone { return try await output(id) }
            // The credits are already back -- the server refunds a failure -- so
            // this is a plain error, not something the caller has to reconcile.
            if current.isFailed {
                throw SnappedCutError(message: current.error ?? "The render failed.", status: 500)
            }
            if Date() > deadline {
                throw SnappedCutError(
                    message: "Job \(id) is still \(current.state.rawValue).", status: 504
                )
            }
            try Task.checkCancellation()
            try await rest(delay)
            delay = min(delay * 1.5, 15)
        }
    }

    private func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}

/// Never the key: a description ends up in logs and crash reports.
extension SnappedCut: CustomStringConvertible {
    public var description: String {
        "SnappedCut(base: \(base), key: \(key.isEmpty ? "unset" : "set"))"
    }
}

struct ErrorBody: Decodable {
    let error: String?
    let retryAfterMs: Int?
    let expected: Int?
}
