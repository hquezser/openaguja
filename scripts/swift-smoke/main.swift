import Foundation

// Smoke test hors Xcode : vérifie les bindings UniFFI compilés dans ce binaire
// (openaguja_ffi.swift) + libopenaguja_ffi.a. Exit 1 au premier échec compté.

var failures = 0
func check(_ condition: Bool, _ name: String) {
    print("\(condition ? "ok" : "FAIL") \(name)")
    if !condition { failures += 1 }
}

// encodeSetTime : 2026-10-26 01:00 locale à UTC+1 (mêmes octets que le test Rust).
do {
    let frame = try encodeSetTime(unixSeconds: 1_792_972_800, utcOffsetSeconds: 3600)
    let expected = Data([
        0x6F, 0x04, 0x71, 0x0C, 0x00, 0xEA, 0x07, 0x0A, 0x1A, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x8F,
    ])
    check(frame == expected, "encodeSetTime(1792972800, +3600)")
    check(frame.prefix(10) == expected.prefix(10), "encodeSetTime prefixe")
} catch {
    check(false, "encodeSetTime a levé \(error)")
}

// decodeFrame : bouton « suivant » de la montre.
do {
    let frame = try decodeFrame(frame: Data([0x6F, 0xD0, 0x71, 0x01, 0x00, 0x03, 0x8F]))
    if case .action(let action) = frame, action == .next {
        check(true, "decodeFrame music-next -> .action(.next)")
    } else {
        check(false, "decodeFrame music-next -> \(frame)")
    }
} catch {
    check(false, "decodeFrame music-next a levé \(error)")
}

// FrameReassembler : la trame de 39 octets du test Rust, en deux morceaux.
do {
    let bytes: [UInt8] = [
        0x6F, 0x76, 0x71, 0x21, 0x00, 0x02, 0x01, 0x06, 0x08, 0x52, 0x61, 0x70,
        0x70, 0x65, 0x6C, 0x52, 0xC3, 0xA9, 0x75, 0x6E, 0x69, 0x6F, 0x6E, 0x32,
        0x30, 0x32, 0x36, 0x31, 0x30, 0x32, 0x36, 0x54, 0x31, 0x37, 0x33, 0x30,
        0x34, 0x35, 0x8F,
    ]
    let frame = Data(bytes)
    check(frame.count == 39, "trame test = 39 octets")
    let r = FrameReassembler()
    check(r.push(chunk: frame.prefix(20)).isEmpty, "reassembler morceau 1/2")
    check(r.push(chunk: frame.suffix(19)) == [frame], "reassembler morceau 2/2")
}

// chunkFrame : 45 octets -> 20 + 20 + 5.
check(
    chunkFrame(frame: Data(repeating: 0xAB, count: 45)).map(\.count) == [20, 20, 5],
    "chunkFrame 45 -> [20, 20, 5]"
)

// encodeMusicInfo / encodeMusicVolume : trames réponse pour 0x8003 (type
// 0x80, pas d'octet ack) — parité Gadgetbridge.
do {
    let expected = Data([
        0x6F, 0xD0, 0x80, 0x07, 0x00, 0x00, 0x50, 0x6C, 0x61, 0x79, 0x65, 0x72, 0x8F,
    ])
    check(
        try encodeMusicInfo(playing: true, title: "Player") == expected,
        "encodeMusicInfo playing"
    )
    check(
        try encodeMusicInfo(playing: false, title: "Player")[5] == 0x01,
        "encodeMusicInfo paused -> 0x01"
    )
    check(
        try encodeMusicVolume(level: 50) == Data([0x6F, 0xD0, 0x80, 0x02, 0x00, 0x02, 50, 0x8F]),
        "encodeMusicVolume(50)"
    )
} catch {
    check(false, "encodeMusic* a levé \(error)")
}

// watchActionId.
check(watchActionId(action: .callRejected) == "call_rejected", "watchActionId(.callRejected)")
check(watchActionId(action: .camera) == "camera", "watchActionId(.camera)")
check(watchActionId(action: .findPhone) == "find_phone", "watchActionId(.findPhone)")
check(watchActionId(action: .sos) == "sos", "watchActionId(.sos)")
check(
    watchActionId(action: .quickReply(
        opcode: 0xDD, text: "", presetCrc: nil, face: "", sender: nil,
        notificationCrc: nil, isContent: false, raw: Data()
    )) == "quick_reply",
    "watchActionId(.quickReply)"
)

// decodeFrame : événements 0xD1 caméra et 0xDD réponse rapide.
do {
    let frame = try decodeFrame(frame: Data([0x6F, 0xD1, 0x71, 0x01, 0x00, 0x00, 0x8F]))
    if case .action(let action) = frame, action == .camera {
        check(true, "decodeFrame camera -> .action(.camera)")
    } else {
        check(false, "decodeFrame camera -> \(frame)")
    }
    let reply = try decodeFrame(frame: Data([0x6F, 0xDD, 0x71, 0x02, 0x00, 0x0D, 0x03, 0x8F]))
    if case .action(let action) = reply,
       case .quickReply(let opcode, _, let presetCrc, _, _, _, let isContent, let raw) = action,
       opcode == 0xDD, raw == Data([0x0D, 0x03]), presetCrc == nil, !isContent
    {
        check(true, "decodeFrame quick-reply -> .action(.quickReply)")
    } else {
        check(false, "decodeFrame quick-reply -> \(reply)")
    }
} catch {
    check(false, "decodeFrame 0xD1/0xDD a levé \(error)")
}

// encodeGenericAck : la trame « return code » renvoyée sur 0x8003.
do {
    check(
        try encodeGenericAck(echoedCmd: 0xD1)
            == Data([0x6F, 0x01, 0x81, 0x02, 0x00, 0xD1, 0x00, 0x8F]),
        "encodeGenericAck(0xD1)"
    )
    check(
        try encodeSetButtonFunction(button: 1, function: 6)
            == Data([0x6F, 0x2E, 0x71, 0x03, 0x00, 0x02, 0x01, 0x06, 0x8F]),
        "encodeSetButtonFunction(1, 6)"
    )
} catch {
    check(false, "encodeGenericAck/SetButtonFunction a levé \(error)")
}

// Surface typée : encodeCommand / parse* (réponses capturées en live).
do {
    check(
        try encodeCommand(command: .getButtonFunctions) == Data([0x6F, 0x2E, 0x70, 0x01, 0x00, 0x00, 0x8F]),
        "encodeCommand(.getButtonFunctions)"
    )
    check(try commandIsRequest(command: .getBattery), "commandIsRequest(.getBattery)")
    check(try commandCode(command: .setLanguage(language: .fr)) == 0x0B, "commandCode(.setLanguage)")
    let buttons = parseButtonFunctions(payload: Data([2, 1, 1, 2, 2, 3, 2, 3, 0, 2, 4, 0]))
    check(buttons.count == 4 && buttons[1] == ButtonFunction(button: 2, function: 3), "parseButtonFunctions(scan)")
    check(
        try parseSetting(setting: .screenTime, payload: Data([0x0A, 0x00])) == .screenTime(seconds: 10),
        "parseSetting(.screenTime)"
    )
    check(zetimeConditionFromWmo(wmoCode: 0, isDay: false) == 18, "zetimeConditionFromWmo(0, nuit)")
    let weather = try encodeCommand(command: .sendWeather(report: WeatherReport(
        location: "GENEVE", currentC: 9, minC: 6, maxC: 12, condition: 17, forecasts: []
    )))
    check(weather.count == 32 && weather[1] == 0x77, "encodeCommand(.sendWeather) complète 3 prévisions")
} catch {
    check(false, "surface typée a levé \(error)")
}

// Télémétrie : trame batterie → TelemetryEvent → JSON schéma.
do {
    let events = decodeTelemetryEvents(
        frame: Data([0x6F, 0x08, 0x80, 0x01, 0x00, 0x40, 0x8F]),
        nowUnix: 1_800_000_000,
        utcOffsetSeconds: 3600,
        buttonFunctions: []
    )
    check(events.count == 1, "decodeTelemetryEvents battery -> 1 événement")
    if let event = events.first {
        check(event.eventType == .battery, "eventType == .battery")
        check(event.timestamp == 1_800_000_000, "timestamp unix")
        let json = try telemetryEventJson(event: event)
        check(
            json.contains("\"event_type\":\"battery\"") && json.contains("\"level\":64"),
            "telemetryEventJson batterie : \(json)"
        )
        // JSON valide et payload objet.
        if let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
           let payload = parsed["payload"] as? [String: Any]
        {
            check(payload["level"] as? Int == 64, "payload.level == 64")
        } else {
            check(false, "JSON télémétrie non analysable : \(json)")
        }
    }
    // Événement watch (caméra) avec table boutons → button_id ambigu.
    let buttons = [
        ButtonFunction(button: 2, function: 6),
        ButtonFunction(button: 4, function: 6),
    ]
    let watchEvents = decodeTelemetryEvents(
        frame: Data([0x6F, 0xD1, 0x71, 0x01, 0x00, 0x00, 0x8F]),
        nowUnix: 1_800_000_000,
        utcOffsetSeconds: 3600,
        buttonFunctions: buttons
    )
    if let event = watchEvents.first, event.eventType == .button,
       let json = try? telemetryEventJson(event: event),
       let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
       let payload = parsed["payload"] as? [String: Any]
    {
        check(payload["action"] as? String == "camera", "button action == camera")
        check((payload["button_candidates"] as? [Int]) == [2, 4], "button_candidates [2,4]")
    } else {
        check(false, "decodeTelemetryEvents caméra -> button")
    }
    // Push cardio temps réel 0xE2.
    let hr = decodeTelemetryEvents(
        frame: Data([0x6F, 0xE2, 0x71, 0x01, 0x00, 0x31, 0x8F]),
        nowUnix: 1_800_000_000,
        utcOffsetSeconds: 3600,
        buttonFunctions: []
    )
    check(hr.first?.eventType == .heartRate, "0xE2 -> heartRate")
    // Encode one-shot HR (0x1A sub 3 — no-op sur A2.0.55, voir doc).
    check(
        (try? encodeHeartRateMeasurement()) == Data([0x6F, 0x1A, 0x71, 0x01, 0x00, 0x03, 0x8F]),
        "encodeHeartRateMeasurement"
    )
    check(
        (try? encodeExitHeartRateMeasurement()) == Data([0x6F, 0x1A, 0x71, 0x01, 0x00, 0x0F, 0x8F]),
        "encodeExitHeartRateMeasurement"
    )
    // Événement généré côté téléphone (ble_status) via le même schéma.
    let status = TelemetryEvent(
        timestamp: 42,
        eventType: .bleStatus,
        payloadJson: "{\"state\":\"connected\",\"rssi\":-55}"
    )
    check(
        (try? telemetryEventJson(event: status))?.contains("\"event_type\":\"ble_status\"") == true,
        "ble_status JSON côté téléphone"
    )
} catch {
    check(false, "télémétrie a levé \(error)")
}

// decodeFrame : octets invalides -> erreur.
do {
    _ = try decodeFrame(frame: Data([0xDE, 0xAD, 0xBE, 0xEF]))
    check(false, "decodeFrame garbage aurait dû lever")
} catch {
    check(true, "decodeFrame garbage -> erreur")
}

if failures > 0 {
    print("\(failures) échec(s)")
    exit(1)
}
print("smoke OK")
