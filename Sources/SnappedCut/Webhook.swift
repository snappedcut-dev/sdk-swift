import Foundation

extension SnappedCut {
    /// Check an `X-Snappedcut-Signature` header (`t=<epoch ms>,v1=<hex>`)
    /// against the raw request body, exactly as received.
    ///
    /// False if `t` is missing or more than five minutes from `nowMs`, if `v1`
    /// is not 64 lowercase hex characters, or if it does not match. The
    /// comparison is constant-time.
    public static func verifyWebhook(
        secret: String,
        rawBody: String,
        signatureHeader: String?,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> Bool {
        var parts: [String: String] = [:]
        for piece in (signatureHeader ?? "").split(separator: ",") {
            let pair = piece.split(separator: "=", maxSplits: 1)
            if pair.count == 2 {
                parts[pair[0].trimmingCharacters(in: .whitespaces)] = String(pair[1])
            }
        }
        guard let stamp = parts["t"], let t = Int64(stamp), abs(nowMs - t) <= 300_000,
              let v1 = parts["v1"], v1.utf8.count == 64,
              v1.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return false }

        let mac = hmacSHA256(key: Array(secret.utf8), message: Array("\(stamp).\(rawBody)".utf8))
        let expected = mac.map { String(format: "%02x", $0) }.joined()
        var diff: UInt8 = 0
        for (a, b) in zip(expected.utf8, v1.utf8) { diff |= a ^ b }
        return diff == 0
    }
}

/* SHA-256 and HMAC in plain Swift, because CryptoKit is Apple-only and the
   package takes no dependencies (swift-crypto would be one). One code path on
   every platform, so the fixed test vector proves it everywhere CI runs.
   Signatures are small, so speed does not matter here. */

func hmacSHA256(key: [UInt8], message: [UInt8]) -> [UInt8] {
    var block = key.count > 64 ? sha256(key) : key
    block += [UInt8](repeating: 0, count: 64 - block.count)
    let inner = sha256(block.map { $0 ^ 0x36 } + message)
    return sha256(block.map { $0 ^ 0x5c } + inner)
}

private let roundConstants: [UInt32] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]

private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

func sha256(_ message: [UInt8]) -> [UInt8] {
    var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                       0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    var padded = message
    padded.append(0x80)
    while padded.count % 64 != 56 { padded.append(0) }
    let bits = UInt64(message.count) * 8
    for shift in stride(from: 56, through: 0, by: -8) {
        padded.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
    }

    var w = [UInt32](repeating: 0, count: 64)
    for start in stride(from: 0, to: padded.count, by: 64) {
        for i in 0..<16 {
            var word: UInt32 = 0
            for j in 0..<4 { word = (word << 8) | UInt32(padded[start + 4 * i + j]) }
            w[i] = word
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = h[0], b = h[1], c = h[2], d = h[3]
        var e = h[4], f = h[5], g = h[6], k = h[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let choose = (e & f) ^ (~e & g)
            let t1 = k &+ s1 &+ choose &+ roundConstants[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ majority
            k = g; g = f; f = e; e = d &+ t1
            d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
        h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ k
    }

    var digest: [UInt8] = []
    for word in h {
        for shift in stride(from: 24, through: 0, by: -8) {
            digest.append(UInt8(truncatingIfNeeded: word >> UInt32(shift)))
        }
    }
    return digest
}
