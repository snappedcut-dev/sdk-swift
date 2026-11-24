# sdk-swift

Swift client for the [Snapped Cut](https://snappedcut.com) cloud render API.
**URLSession and Foundation, and nothing else** — no package dependencies, so
it adds nothing to an app that already links Foundation.

```swift
// Package.swift
.package(url: "https://github.com/snappedcut-dev/sdk-swift", from: "0.1.0")
```

```swift
import SnappedCut

let snapcut = SnappedCut()                       // reads SNAPCUT_KEY

let job = try await snapcut.render(bundle)
print("charged \(job.charged) credits for \(job.priced.seconds)s")

let file = try await snapcut.wait(job.id) { print($0.state.rawValue) }
try file.write(to: URL(filePath: "out.webm"))
```

Get a key from [your account page](https://snappedcut.com/account) — it looks
like `sk_snapcut_…`. Keep it out of the app binary; it spends credits. For a
client app, mint a short-lived token on your own server instead.

Platforms: macOS 13+, iOS 16+, tvOS 16+, watchOS 9+, visionOS 1+, and Linux.

## API

| | |
| --- | --- |
| `SnappedCut(key:base:timeout:chunkSize:transport:)` | `key` falls back to `$SNAPCUT_KEY`. All optional. |
| `account()` | Who the key belongs to, credits left, the price list. |
| `render(_:kind:)` | Queue a render. |
| `job(_:)` / `jobs()` | One job, or every job on the account. |
| `output(_:)` | The rendered bytes. Throws unless the job is done. |
| `wait(_:timeout:onState:)` | Polls to completion, returns the bytes. |

Everything is `async throws` and `Sendable`, and `wait` honours task
cancellation between polls.

## Large bundles resume themselves

`render` sends a bundle under 64 MiB in one request. Above that it uploads in
chunks, and if the connection drops it carries on from **the server's** count of
what it holds, not its own — a `409` carries the expected offset and the client
believes it. Three attempts per chunk; a `4xx` that is not `409` is a real
refusal (no credits, bad bundle, bad key) and stops immediately rather than
retrying its way through your balance.

## You cannot set the price

There is no `seconds` parameter, deliberately. The server reads the timeline
duration out of the bundle's own `project.json` and prices on that, because a
duration supplied by the caller is a price supplied by the caller. What you were
actually charged is in `charged`, with the server's reasoning in `priced`.

## Errors

Every failure is a `SnappedCutError` carrying the HTTP status, and the three
cases you actually branch on are properties:

```swift
do {
    _ = try await snapcut.render(bundle)
} catch let error as SnappedCutError {
    if error.outOfCredits {                      // 402
        topUp()
    } else if error.rateLimited {                // 429
        try await Task.sleep(for: .milliseconds(error.retryAfterMs))
    } else if error.unreachable {                // never reached the server
        retry()
    } else {
        throw error
    }
}
```

A job that fails server-side has **already been refunded** by the time `wait`
throws, so there is nothing to reconcile.

`description` never contains the key — it ends up in logs and crash reports.

## Decoding is forgiving on purpose

Every response field has a default, and an unrecognised `state` from a newer
server decodes as `queued` rather than throwing. A client that cannot parse a
job it could still poll is worse than one that treats an unknown state as
pending — so a server that grows a field, or a state, does not break shipped
apps that cannot be updated.

## What this is not

This talks to the cloud render queue. The editing itself runs on Snapped Cut's
machines, driven from the editor or from an embed — see
[`@snappedcut/embed`](https://github.com/snappedcut-dev/embed) for the web and
[`canvas-react-native`](https://github.com/snappedcut-dev/canvas-react-native)
for apps. This package is for queueing a render from your own backend or tooling.

MIT
