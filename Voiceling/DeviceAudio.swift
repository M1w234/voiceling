import Foundation
import CryptoKit

/// Bounded PCM16/16kHz decoder for encrypted Deskling recordings.
enum DeviceAudio {
    static let maximumSamples = 60 * 16000
    enum Failure: Error { case invalidRecording }
    static func decode(_ body: [String: Any], session: String, key: Data) throws -> [Float] {
        guard session.count == 32, let sessionBytes = bytes(from: session), key.count == 32,
              body["session"] as? String == session,
              let rows = body["packets"] as? [String], (3...471).contains(rows.count) else {
            throw Failure.invalidRecording
        }
        var context = Data("deskling-mic-session-v1|".utf8)
        context.append(sessionBytes)
        let secret = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: context, using: SymmetricKey(data: key))))
        var samples = [Float]()
        for (index, row) in rows.enumerated() {
            guard let packet = Data(base64Encoded: row), (93...4189).contains(packet.count) else {
                throw Failure.invalidRecording
            }
            let p = [UInt8](packet)
            let count = p.count - 93
            let kind: UInt8 = index == 0 ? 0 : index == rows.count - 1 ? 2 : 1
            func u32(_ offset: Int) -> UInt32 {
                (0..<4).reduce(UInt32(0)) { $0 | UInt32(p[offset + $1]) << (8 * $1) }
            }
            guard Array(p[0..<4]) == Array("DMA1".utf8), p[4] == kind,
                  p[5..<21].map({ String(format: "%02x", $0) }).joined() == session,
                  u32(21) == UInt32(index), Array(p[33..<41]) == Array(p[5..<13]),
                  u32(41) == UInt32(index), count % 2 == 0,
                  (kind == 1 ? count > 0 : count == 0),
                  samples.count + count / 2 <= maximumSamples else { throw Failure.invalidRecording }
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: packet[33..<45]),
                                           ciphertext: packet[45..<(45 + count)],
                                           tag: packet[(45 + count)..<(61 + count)])
            let pcm = [UInt8](try AES.GCM.open(box, using: secret, authenticating: packet[0..<33]))
            for offset in stride(from: 0, to: pcm.count, by: 2) {
                let bits = UInt16(pcm[offset]) | UInt16(pcm[offset + 1]) << 8
                samples.append(Float(Int16(bitPattern: bits)) / 32768)
            }
        }
        return samples
    }
    static func key(from hex: String) -> Data? {
        guard hex.count == 64 else { return nil }
        return bytes(from: hex)
    }
    private static func bytes(from hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data()
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let end = hex.index(cursor, offsetBy: 2)
            guard let byte = UInt8(hex[cursor..<end], radix: 16) else { return nil }
            data.append(byte); cursor = end
        }
        return data
    }
}
