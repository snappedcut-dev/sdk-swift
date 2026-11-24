import Foundation

/// What the server decided the job was, and therefore what it cost.
public struct Priced: Codable, Equatable, Sendable {
    public let seconds: Double
    public let project: String
    public let layers: Int

    public init(seconds: Double = 0, project: String = "", layers: Int = 0) {
        self.seconds = seconds
        self.project = project
        self.layers = layers
    }

    /// Defaults for every field: a response is a claim from across a network,
    /// and a missing key should not fail the decode of a job that exists.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        seconds = try values.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        project = try values.decodeIfPresent(String.self, forKey: .project) ?? ""
        layers = try values.decodeIfPresent(Int.self, forKey: .layers) ?? 0
    }
}

public enum JobState: String, Codable, Sendable {
    case queued, running, done, failed

    /// An unknown state from a newer server is `queued`, not a decode failure:
    /// a client that cannot parse a job it could still poll is worse.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = JobState(rawValue: raw) ?? .queued
    }
}

public struct Job: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let state: JobState
    public let error: String?
    public let seconds: Double
    public let createdAt: Int
    public let updatedAt: Int

    public var isDone: Bool { state == .done }
    public var isFailed: Bool { state == .failed }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? "cloud-render"
        state = try values.decodeIfPresent(JobState.self, forKey: .state) ?? .queued
        error = try values.decodeIfPresent(String.self, forKey: .error)
        seconds = try values.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        createdAt = try values.decodeIfPresent(Int.self, forKey: .createdAt) ?? 0
        updatedAt = try values.decodeIfPresent(Int.self, forKey: .updatedAt) ?? 0
    }
}

/// A job plus what queueing it cost.
public struct QueuedJob: Sendable {
    public let job: Job
    public let charged: Int
    public let credits: Int
    public let priced: Priced

    public var id: String { job.id }
}

struct QueuedBody: Decodable {
    let job: Job
    let charged: Int
    let credits: Int
    let priced: Priced

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        job = try values.decode(Job.self, forKey: .job)
        charged = try values.decodeIfPresent(Int.self, forKey: .charged) ?? 0
        credits = try values.decodeIfPresent(Int.self, forKey: .credits) ?? 0
        priced = try values.decodeIfPresent(Priced.self, forKey: .priced) ?? Priced()
    }

    enum CodingKeys: String, CodingKey { case job, charged, credits, priced }
}

public struct Account: Codable, Equatable, Sendable {
    public let id: String
    public let email: String
    public let credits: Int
    public let prices: [String: Int]

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        email = try values.decodeIfPresent(String.self, forKey: .email) ?? ""
        credits = try values.decodeIfPresent(Int.self, forKey: .credits) ?? 0
        prices = try values.decodeIfPresent([String: Int].self, forKey: .prices) ?? [:]
    }
}

struct JobsBody: Decodable {
    let jobs: [Job]

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        jobs = try values.decodeIfPresent([Job].self, forKey: .jobs) ?? []
    }

    enum CodingKeys: String, CodingKey { case jobs }
}

struct ChunkBody: Decodable {
    let upload: String
    let received: Int
}
