import SwiftUI
import OpenAgujaCore

/// Vue lab : dump mémoire en lecture seule via l'opcode 0xEE.
/// Le binaire est écrit dans Documents avec un .txt de métadonnées
/// (adresse de base + plages illisibles), partageable en pièce jointe.
struct MemoryDumpView: View {
    @EnvironmentObject private var bluetooth: ZeTimeBluetoothManager
    @State private var startHex = "0"
    @State private var countHex = "12000"
    @State private var running = false
    @State private var result: ZeTimeBluetoothManager.DumpResult?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?
    @State private var share: ShareItem?
    @State private var initFlag: Int?
    @State private var confirmInit = false

    private var start: UInt32? { Self.hex(startHex) }
    private var count: UInt32? { Self.hex(countHex) }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Start")
                    Spacer()
                    Text("0x")
                    TextField("0", text: $startHex)
                        .keyboardType(.asciiCapable)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                }
                HStack {
                    Text("Size")
                    Spacer()
                    Text("0x")
                    TextField("12000", text: $countHex)
                        .keyboardType(.asciiCapable)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                }
                HStack(spacing: 8) {
                    preset("boot0", "0", "6800")
                    preset("bootloader", "0", "12000")
                    preset("SRAM", "10000000", "40000")
                }
            } header: {
                Text("Range")
            } footer: {
                Text("Read-only (opcode 0xEE, 64 bytes per request). An unmapped address can freeze the watch — only dump already-validated ranges.")
            }

            Section {
                if running {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: bluetooth.dumpProgress ?? 0)
                        Text("\(Int((bluetooth.dumpProgress ?? 0) * 100)) %")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel", role: .destructive) { task?.cancel() }
                } else {
                    Button("Start dump") { startDump() }
                        .disabled(start == nil || count == nil || !bluetooth.isReady)
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                HStack {
                    Text("initFlag")
                    Spacer()
                    Text(initFlag.map { $0 == 0 ? "0 (QR / init pending)" : "\($0)" } ?? "—")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
                Button("Read initFlag") {
                    Task { initFlag = try? await bluetooth.checkInitFlag() }
                }
                .disabled(!bluetooth.isReady)
                Button("Complete setup → watch face") { confirmInit = true }
                    .disabled(!bluetooth.isReady)
            } header: {
                Text("Init (0x94)")
            } footer: {
                Text("0x94 SET [0x00] triggers out-of-box init (defaults + persisted flag) — leaves the QR screen for the watch face, like the official app init.")
            }

            if let result {
                Section("Result") {
                    LabeledContent("Base", value: String(format: "0x%06X", result.base))
                    LabeledContent("Bytes", value: "\(result.data.count)")
                    LabeledContent("Gaps", value: "\(result.gaps.count)")
                    Button {
                        share = ShareItem(url: result.file)
                    } label: {
                        Label("Share dump…", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle("Lab")
        .sheet(item: $share) { item in
            ShareSheet(items: [item.url])
        }
        .confirmationDialog("Complete setup?",
                            isPresented: $confirmInit,
                            titleVisibility: .visible) {
            Button("Complete setup") {
                Task {
                    try? await bluetooth.completeInit()
                    initFlag = try? await bluetooth.checkInitFlag()
                }
            }
        } message: {
            Text("Sends 0x94 SET [0x00]: out-of-box init + persisted initFlag=1 — the watch leaves QR for the watch face.")
        }
        .task { initFlag = try? await bluetooth.checkInitFlag() }
        .onDisappear { task?.cancel() }
    }

    private func preset(_ label: String, _ s: String, _ c: String) -> some View {
        Button(label) {
            startHex = s
            countHex = c
        }
        .buttonStyle(.bordered)
        .font(.caption)
    }

    private func startDump() {
        guard let start, let count else { return }
        running = true
        result = nil
        failure = nil
        task = Task {
            do {
                result = try await bluetooth.dumpMemory(start: start, count: count)
            } catch is CancellationError {
                failure = "Cancelled"
            } catch {
                failure = error.localizedDescription
            }
            running = false
        }
    }

    private static func hex(_ text: String) -> UInt32? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { t.removeFirst(2) }
        return UInt32(t, radix: 16)
    }
}
