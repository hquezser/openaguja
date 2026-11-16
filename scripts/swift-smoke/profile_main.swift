import Foundation

/// Smoke test du modèle de profil : décodage de l'exemple fourni,
/// aller-retour Codable des modes (boutons à clés texte, commandes à
/// plage horaire), refus des cibles inconnues et absence de jeton dans
/// l'export. Compilé avec Profile.swift, IntegrationConfig.swift,
/// ActionRouter.swift et les dépendances minimales (MacDaemonBridge,
/// LogStore, Keychain) — aucun binding FFI requis.
@main
struct ProfileSmoke {
    static func main() throws {
        // 1. L'exemple fourni dans contrib/ décode et se valide.
        //    (#filePath : scripts/swift-smoke/profile_main.swift → racine)
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // swift-smoke
            .deletingLastPathComponent()  // scripts
            .deletingLastPathComponent()  // racine du dépôt
        let exampleURL = repoRoot.appendingPathComponent("contrib/profiles/example.json")
        let exampleData = try Data(contentsOf: exampleURL)
        let example = try AppProfile.decode(exampleData)
        assert(example.version == 1, "version du profil exemple")
        assert(example.modes?.count == 2, "deux modes dans l'exemple")
        print("1. example.json décodé (\(example.modes?.count ?? 0) modes)")

        // 2. Aller-retour d'un profil complet : boutons {"3":6,"4":16},
        //    commande à plage horaire et table de cibles.
        var mode = RouteMode(
            id: "test", label: "Test", symbol: "flask",
            targets: ["play": .appleMusic, "camera": .macDaemon]
        )
        mode.bindings = RouteMode.Bindings(
            onActivate: ["hello"],
            onActivateTimed: [RouteMode.TimedCommand(from: 22, to: 6, command: "night")],
            heartRateMinutes: 15,
            daemonCommands: ["camera": "dictation_start"],
            daemonEndCommands: ["find_phone": "dictation_stop"],
            buttons: [3: 6, 4: 16],
            musicViaNowPlaying: true
        )
        let profile = AppProfile(
            webhook: WebhookConfig(name: "Test", actionURL: "https://example.com/hook"),
            macDaemonURL: "http://mac.local:9876",
            routing: AppProfile.Routing(
                targets: ["play": .appleMusic],
                shortcuts: ["sos": "Alerte"],
                hapticOnSuccess: false,
                hapticOnFailure: true,
                hapticPattern: "double"
            ),
            modes: [mode]
        )
        let roundTrip = try AppProfile.decode(try profile.jsonData())
        assert(roundTrip == profile, "round-trip AppProfile")
        assert(roundTrip.modes?.first?.bindings.buttons == [3: 6, 4: 16], "boutons UInt8")
        assert(roundTrip.modes?.first?.bindings.onActivateTimed.first?.command == "night", "timed command")
        print("2. round-trip OK (boutons, timed command, cibles)")

        // 3. Le JSON encodé écrit les boutons avec des clés texte :
        //    "buttons":{"3":6… — JSON n'a pas de clés numériques.
        let json = String(decoding: try profile.jsonData(), as: UTF8.self)
        let compact = String(json.filter { !$0.isWhitespace })
        assert(compact.contains("\"buttons\":{\"3\":6"), "clés boutons texte dans le JSON")
        print("3. boutons encodés en clés texte")

        // 4. Une cible inconnue fait échouer le décodage en la nommant.
        let bad = #"{"version":1,"routing":{"targets":{"play":"no_such_target"}}}"#.data(using: .utf8)!
        do {
            _ = try AppProfile.decode(bad)
            fatalError("une cible inconnue aurait dû être refusée")
        } catch {
            assert("\(error)".contains("no_such_target"), "l'erreur nomme la cible : \(error)")
            print("4. cible inconnue refusée : \(error)")
        }

        // 5. L'export ne contient jamais de jeton.
        let exported = String(decoding: try AppProfile.export().jsonData(), as: UTF8.self)
        assert(!exported.contains("\"token\""), "export sans jeton")
        print("5. export sans \"token\"")

        // Arguments supplémentaires : chemins de profils à valider
        // (ex. la config personnelle hors dépôt).
        for path in CommandLine.arguments.dropFirst() {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let profile = try AppProfile.decode(data)
            print("profil additionnel OK : \(path) (\(profile.modes?.count ?? 0) modes)")
        }

        print("profile smoke OK")
    }
}
