import Foundation

#if canImport(OpenAgujaCore)
    import OpenAgujaCore
#endif

/// Dump mémoire en lecture seule via l'opcode 0xEE (lab).
///
/// Chaque lecture passe par `request()` donc par la file `exclusive()` :
/// aucune autre requête ne peut s'intercaler et mélanger les réponses.
/// Le lien BLE perd parfois des notifications en tête ou en milieu de
/// trame — une charge utile plus courte que `len` est retentée, jamais
/// acceptée telle quelle (le réassembleur Python a montré qu'elle serait
/// décalée).
extension ZeTimeBluetoothManager {
    struct DumpResult {
        /// Adresse absolue du premier octet de `data`.
        let base: UInt32
        let data: Data
        let file: URL
        /// Plages restées illisibles après les retries, en offsets relatifs à `base`.
        let gaps: [Range<Int>]
        let metaFile: URL
    }

    /// Dump `[start, start+count)` par lectures de `chunk` octets (≤ 0x40,
    /// limite confirmée sur A2.0.55). Écrit le binaire et un fichier .txt
    /// de métadonnées (base + trous) dans Documents et les renvoie.
    @MainActor
    func dumpMemory(start: UInt32, count: UInt32, chunk: UInt8 = 0x40) async throws -> DumpResult {
        guard isReady else { throw WatchError.notConnected }
        guard count > 0 else { throw WatchError.refused("dump", 0) }

        var image = Data(repeating: 0, count: Int(count))
        var gaps: [Range<Int>] = []
        var consecutiveFailures = 0
        let end = start + count
        var cursor = start
        dumpProgress = 0
        defer { dumpProgress = nil }
        log.add(.info, String(format: "Dump 0x%06X–0x%06X (%u lectures de %u o)", start, end,
                            (count + UInt32(chunk) - 1) / UInt32(chunk), chunk))

        while cursor < end {
            try Task.checkCancellation()
            let n = min(UInt32(chunk), end - cursor)
            let offset = Int(cursor - start)
            var payload: Data?
            var attempts = 0
            while payload == nil && attempts < 3 {
                attempts += 1
                do {
                    let p = try await request(
                        .readMemory(addr: cursor, len: UInt8(n)),
                        label: String(format: "peek 0x%06X", cursor),
                        timeout: 1.5
                    )
                    if p.count == Int(n) {
                        payload = p
                    } else {
                        log.add(.error, String(
                            format: "peek 0x%06X: %u/%u bytes received — try %u/3",
                            cursor, p.count, n, attempts))
                    }
                } catch WatchError.refused {
                    // Refus catégorique (opcode inconnu / adresse non
                    // mappée) : retenter ne changerait rien.
                    log.add(.error, String(format: "peek 0x%06X: refused by the watch", cursor))
                    attempts = 3
                } catch {
                    log.add(.error, String(
                        format: "peek 0x%06X : %@ — essai %u/3",
                        cursor, error.localizedDescription, attempts))
                }
            }

            if let payload {
                image.replaceSubrange(offset..<(offset + Int(n)), with: payload)
                consecutiveFailures = 0
            } else {
                gaps.append(offset..<(offset + Int(n)))
                consecutiveFailures += 1
                // 8 lectures d'affilée perdues = lien mort ou toute la
                // plage refusée : on sauve ce qu'on a plutôt que rien.
                if consecutiveFailures >= 8 || cursor == start {
                    log.add(.error, "Dump: consecutive failures, stopping at " +
                        String(format: "0x%06X (%u bytes recovered)", cursor, offset))
                    break
                }
            }
            cursor += n
            // ~15 publications/s inonderaient SwiftUI : on ne rafraîchit
            // la progression qu'aux frontières de 512 octets.
            if (cursor - start) & 0x1FF == 0 || cursor == end {
                dumpProgress = Double(cursor - start) / Double(count)
            }
        }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let base = String(format: "memdump_0x%06X_0x%06X_%@", start, end, stamp)
        let file = dir.appendingPathComponent("\(base).bin")
        try image.write(to: file)

        var meta = "base=0x" + String(format: "%06X", start)
            + "\nend=0x" + String(format: "%06X", end)
            + "\nbytes=\(image.count)\n"
        meta += gaps.isEmpty ? "gaps=none\n"
            : "gaps=" + gaps.map {
                String(format: "0x%06X-0x%06X", start + UInt32($0.lowerBound), start + UInt32($0.upperBound))
            }.joined(separator: ",") + "\n"
        let metaFile = dir.appendingPathComponent("\(base).txt")
        try meta.write(to: metaFile, atomically: true, encoding: .utf8)

        log.add(.info, "Dump done: \(image.count) bytes, \(gaps.count) gap(s) → \(file.lastPathComponent)")
        return DumpResult(base: start, data: image, file: file, gaps: gaps, metaFile: metaFile)
    }

    /// initFlag courant (0x94 GET) : 0 = QR en attente, 1 = init terminée.
    @MainActor
    func checkInitFlag() async throws -> Int {
        let payload = try await request(.getInitFlag, label: "checkInit")
        return payload.first.map(Int.init) ?? -1
    }

    /// 0x94 SET `[0x00]` — complète l'init out-of-box : quitte l'écran QR
    /// vers le cadran (équivalent de l'init de l'app officielle).
    @MainActor
    func completeInit() async throws {
        try await perform(.completeInit, label: String(localized: "Complete setup"))
    }
}
