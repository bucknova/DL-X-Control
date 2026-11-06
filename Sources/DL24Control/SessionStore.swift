import DL24Core
import Foundation
import Observation

struct SessionMark: Codable, Identifiable, Equatable {
    var id = UUID()
    var t: Double
    var text: String
}

struct SessionMeta: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var date: Date
    var transport: String
    var summary = SessionSummary()
    var stop: StopReason?
    var marks: [SessionMark] = []
    var result: ProgramResult?
    var ratedAh: Double?
}

struct CounterSnapshot: Codable {
    var date: Date
    var reset: String
    var milliampHours: Double
    var milliwattHours: Double
    var runSeconds: Int
}

/// Sessions live in Application Support as meta.json plus an append-only
/// samples.csv, so a crash loses at most a second of data.
@MainActor @Observable
final class SessionStore {
    private(set) var sessions: [SessionMeta] = []
    private(set) var programs: [TestProgram] = []
    let root: URL
    private var cache: [UUID: [Sample]] = [:]

    init(demo: Bool) {
        let base = demo
            ? FileManager.default.temporaryDirectory.appendingPathComponent("DL24ControlDemo-\(ProcessInfo.processInfo.processIdentifier)")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DL24 Control")
        root = base
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        reload()
        loadPrograms()
    }

    private var sessionsDir: URL { root.appendingPathComponent("Sessions") }
    private var programsURL: URL { root.appendingPathComponent("programs.json") }
    func directory(_ id: UUID) -> URL { sessionsDir.appendingPathComponent(id.uuidString) }
    func samplesURL(_ id: UUID) -> URL { directory(id).appendingPathComponent("samples.csv") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        sessions = dirs.compactMap { dir in
            guard let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")) else { return nil }
            return try? Self.decoder.decode(SessionMeta.self, from: d)
        }.sorted { $0.date > $1.date }
    }

    func save(_ meta: SessionMeta) {
        try? FileManager.default.createDirectory(at: directory(meta.id), withIntermediateDirectories: true)
        if let d = try? Self.encoder.encode(meta) {
            try? d.write(to: directory(meta.id).appendingPathComponent("meta.json"), options: .atomic)
        }
        if let i = sessions.firstIndex(where: { $0.id == meta.id }) { sessions[i] = meta } else { sessions.insert(meta, at: 0) }
        sessions.sort { $0.date > $1.date }
        cache[meta.id] = nil
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory(id))
        sessions.removeAll { $0.id == id }
        cache[id] = nil
    }

    func samples(for id: UUID) -> [Sample] {
        if let c = cache[id] { return c }
        guard let text = try? String(contentsOf: samplesURL(id), encoding: .utf8) else { return [] }
        let rows = text.split(separator: "\n").dropFirst().compactMap { SampleCSV.parse(line: $0) }
        cache[id] = rows
        return rows
    }

    func exportJSON(_ meta: SessionMeta) -> Data? {
        struct Export: Encodable { let session: SessionMeta; let samples: [Sample] }
        return try? Self.encoder.encode(Export(session: meta, samples: samples(for: meta.id)))
    }

    func appendCounterSnapshot(_ s: CounterSnapshot) {
        let url = root.appendingPathComponent("counter-resets.jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(s) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    // MARK: Programs

    private func loadPrograms() {
        if let d = try? Data(contentsOf: programsURL), let p = try? Self.decoder.decode([TestProgram].self, from: d), !p.isEmpty {
            programs = p
        } else {
            programs = TestProgram.templates
        }
    }

    func savePrograms(_ list: [TestProgram]) {
        programs = list
        if let d = try? Self.encoder.encode(list) { try? d.write(to: programsURL, options: .atomic) }
    }

    func lastResults(named name: String) -> [ProgramResult] {
        sessions.compactMap(\.result).filter { $0.programName == name }.sorted { $0.date > $1.date }
    }
}

/// One session being written. Rows are buffered and flushed once a second.
@MainActor
final class SessionRecorder {
    private(set) var meta: SessionMeta
    private(set) var samples: [Sample] = []
    private let store: SessionStore
    private var handle: FileHandle?
    private var pending = ""
    private var lastFlush = Date()
    private let startCounters: (Double, Double)

    init(store: SessionStore, name: String, transport: String) {
        self.store = store
        meta = SessionMeta(name: name, date: Date(), transport: transport)
        startCounters = (0, 0)
        store.save(meta)
        let url = store.samplesURL(meta.id)
        FileManager.default.createFile(atPath: url.path, contents: (SampleCSV.header + "\n").data(using: .utf8))
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func append(_ s: Sample) {
        samples.append(s)
        pending += SampleCSV.row(s) + "\n"
        if Date().timeIntervalSince(lastFlush) >= 1 { flush() }
    }

    func flush() {
        guard !pending.isEmpty, let d = pending.data(using: .utf8) else { return }
        try? handle?.write(contentsOf: d)
        pending = ""
        lastFlush = Date()
    }

    func mark(_ text: String) {
        meta.marks.append(SessionMark(t: samples.last?.t ?? 0, text: text))
        store.save(meta)
    }

    func finish(stop: StopReason?, result: ProgramResult?, linkDrops: Int) -> SessionMeta {
        flush()
        try? handle?.close()
        handle = nil
        meta.stop = stop
        meta.result = result
        meta.summary = SessionSummary(samples: samples, linkDrops: linkDrops)
        store.save(meta)
        return meta
    }
}
