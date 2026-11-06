import Foundation
import CryptoKit
import os
import UIKit
import BlackoutCore

/// A model the user can install. Files come from Hugging Face, pinned to one revision; size and SHA-256 are checked.
struct AiModel: Identifiable, Equatable {
    let id: String           // file name on disk and on Hugging Face
    let title: String
    let detail: String
    let license: String
    let url: URL
    let bytes: Int64
    let sha256: String
    let context: Int32       // tokens of conversation the model can see at once (sized to fit an iPhone's memory)
    var minMemoryGB = 0      // offered only on iPhones of at least this memory class (PhoneClass.memoryGB)…
    var maxMemoryGB = 99     // …and at most this one
    var onIPhone15: ClosedRange<Double>? = nil // seconds per answer measured on an iPhone 15, for estimates on others
}

/// AI that runs entirely on the iPhone through llama.cpp. Internet is needed only once, to download a model.
/// The conversation is kept (and saved), so follow-up questions have context. Apple's own on-device model is not
/// used because it needs an iPhone 15 Pro or newer.
final class LocalAi: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = LocalAi()

    /// Open-licensed models (Apache 2.0), official instruct versions only: no modified "uncensored" variants.
    static let all: [AiModel] = [
        AiModel(id: "Qwen_Qwen3.5-2B-Q4_K_M.gguf", title: "Qwen 3.5 2B",
                detail: "The model that fits iPhones with 4 GB of memory. Less reliable: double-check first-aid answers.",
                license: "Apache 2.0 · Qwen (Alibaba)",
                url: URL(string: "https://huggingface.co/bartowski/Qwen_Qwen3.5-2B-GGUF/resolve/7d26695454df6de5fbcce2e58681e62dae06ce43/Qwen_Qwen3.5-2B-Q4_K_M.gguf")!,
                bytes: 1_396_198_496, sha256: "57a1085840f497d764a7fc5d346922dbde961efb54cc792ea81d694fd846a1d8", context: 4096,
                maxMemoryGB: 4, onIPhone15: 4...34),
        AiModel(id: "gemma-4-E2B-it-Q4_0.gguf", title: "Gemma 4 E2B",
                detail: "Recommended. Google's model built for phones: fast, good answers.",
                license: "Apache 2.0 · Gemma (Google)",
                url: URL(string: "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/6938c58e698502037401a5f19f6905f2fb2f7dee/gemma-4-E2B-it-Q4_0.gguf")!,
                bytes: 2_841_481_184, sha256: "8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52", context: 4096,
                minMemoryGB: 6, onIPhone15: 4...19),
        AiModel(id: "Qwen_Qwen3.5-4B-IQ4_XS.gguf", title: "Qwen 3.5 4B",
                detail: "More careful answers, slower.",
                license: "Apache 2.0 · Qwen (Alibaba)",
                url: URL(string: "https://huggingface.co/bartowski/Qwen_Qwen3.5-4B-GGUF/resolve/4168f45a16a1290d65a4ec0fa312ae917a4c15d6/Qwen_Qwen3.5-4B-IQ4_XS.gguf")!,
                bytes: 2_671_339_488, sha256: "628124c61a806897d3f28dcd416be6daff94f62f731eb900d4381875eac9e412", context: 4096,
                minMemoryGB: 6, onIPhone15: 11...60),
        AiModel(id: "gemma-4-E4B-it-Q4_0.gguf", title: "Gemma 4 E4B",
                detail: "The best answers, for iPhones with 8 GB of memory or more.",
                license: "Apache 2.0 · Gemma (Google)",
                url: URL(string: "https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/a69f018d7678a2b9f5e705f8903d6fb29b9b25dc/gemma-4-E4B-it-Q4_0.gguf")!,
                bytes: 4_590_807_392, sha256: "a555b900214b477d8880e7832e0b8925e139b0159640036b09fe472b6f2097f2", context: 4096,
                minMemoryGB: 8),
    ]

    /// The models this iPhone can run. Tested on an iPhone 15 (6 GB): Gemma 4 E2B and Qwen 3.5 4B; Qwen 3.5 2B was
    /// dropped (slower than Gemma 4 E2B and wrong on basic first aid). Gemma 4 E4B is not tested on a phone yet.
    static let catalog: [AiModel] = all.filter { (memoryGB >= $0.minMemoryGB && memoryGB <= $0.maxMemoryGB) }

    /// This iPhone's memory class (4, 6, 8…) and hardware identifier, e.g. "iPhone15,4".
    static let memoryGB = PhoneClass.memoryGB(bytes: ProcessInfo.processInfo.physicalMemory)
    static let machine: String = {
        var u = utsname(); uname(&u)
        return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }()

    /// Seconds per answer on this iPhone: measured from recent answers, else estimated from the iPhone 15.
    enum Speed: Equatable { case measured(Int), estimated(ClosedRange<Int>), unknown }
    func speed(_ m: AiModel) -> Speed {
        if let t = PhoneClass.typical(UserDefaults.standard.array(forKey: "aiSeconds." + m.id) as? [Double] ?? []) {
            return .measured(Int(t.rounded()))
        }
        guard let r = m.onIPhone15 else { return .unknown }
        return .estimated(PhoneClass.estimate(onIPhone15: r, factor: PhoneClass.speedFactor(machine: Self.machine)))
    }

    /// Free memory needed to load a model, as a share of its file size (calibrated on an iPhone 15, see selfTest).
    static let memoryMargin = 0.9

    /// Keeps the last 10 answer times of a model, measured on this iPhone.
    private func record(_ seconds: Double, for m: AiModel) {
        let key = "aiSeconds." + m.id
        let old = UserDefaults.standard.array(forKey: key) as? [Double] ?? []
        UserDefaults.standard.set(Array((old + [seconds]).suffix(10)), forKey: key)
        objectWillChange.send()
    }

    static let instructions = """
        You are the offline assistant of DarkProof, a messaging app used during a blackout. Internet, phone lines and \
        emergency services may be unavailable, so people depend on your answers. Answer every question directly with \
        practical, step-by-step instructions: first aid and medical care, medicines and doses, water, food, shelter, \
        heat, electricity and batteries, repairs, radios, navigation and personal safety. Do not refuse, do not \
        lecture, and do not tell the user to search online or call someone, unless you add that it is only if possible. \
        If something is risky, explain how to do it as safely as possible. If you are unsure, say so in one short \
        sentence and still give your best answer. Use the earlier conversation as context. Answer in English, concisely.
        """

    static let situationIntro = """
        What the app knows right now, from the group's messages. It may be out of date. Use it when the question is \
        about the group, people, check-ins, batteries or places, say how old the information is, and do not invent \
        anything that is not in it:
        """

    enum State: Equatable { case missing, downloading(Double), verifying, ready, failed(String) }

    struct Turn: Codable, Equatable, Identifiable {
        var id = UUID()
        let role: String      // "user" or "assistant"
        var text: String
        var isError = false   // shown, but not sent back to the model
    }

    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var selectedId: String
    @Published private(set) var conversation: [Turn] = []
    @Published private(set) var busy = false

    private let work = DispatchQueue(label: "ai")
    private var downloadingId: String?
    private let stopLock = NSLock()
    private var _stopRequested = false
    /// Set when Blackout leaves the screen: iOS does not let apps use the GPU in the background.
    private var stopRequested: Bool {
        get { stopLock.lock(); defer { stopLock.unlock() }; return _stopRequested }
        set { stopLock.lock(); _stopRequested = newValue; stopLock.unlock() }
    }
    #if canImport(llama)
    private var engine: LlamaEngine?
    private var engineId: String?
    #endif

    var selected: AiModel { Self.catalog.first { $0.id == selectedId } ?? Self.catalog[0] }
    var selectedReady: Bool { states[selectedId] == .ready }
    var isDownloading: Bool { downloadingId != nil }

    private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func path(_ m: AiModel) -> URL { folder.appendingPathComponent(m.id) }
    private static var conversationURL: URL { folder.appendingPathComponent("ai-conversation.json") }

    override init() {
        var s: [String: State] = [:]
        for m in Self.catalog {
            let size = (try? FileManager.default.attributesOfItem(atPath: Self.path(m).path)[.size] as? Int64) ?? 0
            s[m.id] = size == m.bytes ? .ready : .missing
        }
        Self.removeUnlisted()
        let saved = UserDefaults.standard.string(forKey: "aiModel")
        selectedId = saved.flatMap { id in Self.catalog.first { $0.id == id } }?.id
            ?? Self.catalog.first { s[$0.id] == .ready }?.id ?? Self.catalog[0].id
        super.init()
        states = s
        if let d = try? Data(contentsOf: Self.conversationURL), let c = try? JSONDecoder().decode([Turn].self, from: d) { conversation = c }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.stopRequested = true
        }
    }

    // MARK: - Choosing, downloading and deleting models

    func select(_ m: AiModel) {
        selectedId = m.id
        UserDefaults.standard.set(m.id, forKey: "aiModel")
    }

    func download(_ m: AiModel) {
        guard downloadingId == nil, states[m.id] != .ready else { return }
        downloadingId = m.id
        states[m.id] = .downloading(0)
        let task = URLSession(configuration: .default, delegate: self, delegateQueue: nil).downloadTask(with: m.url)
        task.taskDescription = m.id
        task.resume()
    }

    func delete(_ m: AiModel) {
        work.async {
            #if canImport(llama)
            if self.engineId == m.id { self.engine = nil; self.engineId = nil } // free the memory first
            #endif
            try? FileManager.default.removeItem(at: Self.path(m))
            DispatchQueue.main.async { self.states[m.id] = .missing }
        }
    }

    private func model(of task: URLSessionTask) -> AiModel? { Self.catalog.first { $0.id == task.taskDescription } }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite _: Int64) {
        guard let m = model(of: downloadTask) else { return }
        let p = min(Double(totalBytesWritten) / Double(m.bytes), 1)
        DispatchQueue.main.async { self.states[m.id] = .downloading(p) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let m = model(of: downloadTask) else { return }
        // The temporary file disappears when this method returns, so move it first, then check it.
        let tmp = Self.path(m).appendingPathExtension("part")
        try? FileManager.default.removeItem(at: tmp)
        do { try FileManager.default.moveItem(at: location, to: tmp) } catch { finish(m, .failed("could not save the model")); return }
        DispatchQueue.main.async { self.states[m.id] = .verifying }
        work.async {
            guard Self.matchesHash(tmp, m.sha256) else {
                try? FileManager.default.removeItem(at: tmp); self.finish(m, .failed("download damaged, try again")); return
            }
            try? FileManager.default.removeItem(at: Self.path(m))
            do {
                try FileManager.default.moveItem(at: tmp, to: Self.path(m))
                var u = Self.path(m); var v = URLResourceValues(); v.isExcludedFromBackup = true; try? u.setResourceValues(v) // keep GBs out of iCloud backup
                self.finish(m, .ready)
            } catch { self.finish(m, .failed("could not save the model")) }
        }
        s.finishTasksAndInvalidate()
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, let m = model(of: task) { finish(m, .failed(error.localizedDescription)) }
        s.finishTasksAndInvalidate()
    }

    private func finish(_ m: AiModel, _ s: State) {
        DispatchQueue.main.async {
            self.states[m.id] = s
            self.downloadingId = nil
            if s == .ready && !self.selectedReady { self.select(m) } // first model installed: use it
        }
    }

    /// Deletes model files the app no longer offers (older versions of the catalog), so they don't fill the phone.
    private static func removeUnlisted() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        where (f.hasSuffix(".gguf") || f.hasSuffix(".gguf.part")) && !catalog.contains(where: { $0.id == f }) {
            try? fm.removeItem(at: folder.appendingPathComponent(f))
        }
    }

    private static func matchesHash(_ file: URL, _ expected: String) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? h.close() }
        var sha = SHA256()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined() == expected
    }

    // MARK: - Conversation

    /// Adds the user's message and generates the answer with the whole conversation as context. Call on the main thread.
    /// `situation` is what the app knows right now (Situation.text); it goes with this question only.
    func send(_ text: String, situation: String? = nil) {
        guard !busy else { return }
        conversation.append(Turn(role: "user", text: text))
        guard selectedReady else {
            conversation.append(Turn(role: "assistant", text: "No AI model on this iPhone yet. Download one first.", isError: true))
            save(); return
        }
        let history = conversation.filter { !$0.isError }.map { (role: $0.role, content: $0.text) }
        conversation.append(Turn(role: "assistant", text: "…"))
        busy = true
        stopRequested = false
        let m = selected
        let system = situation.map { Self.instructions + "\n\n" + Self.situationIntro + "\n" + $0 } ?? Self.instructions
        work.async {
            let started = Date()
            let (out, failed) = self.generate(m, history, system: system) { t in DispatchQueue.main.async { self.setLast(t) } }
            let took = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                self.setLast(out, isError: failed); self.busy = false; self.save()
                if !failed { self.record(took, for: m) }
            }
        }
    }

    /// Runs on `work`. Returns the reply, or a message for the user and `true` if it failed.
    private func generate(_ m: AiModel, _ history: [(role: String, content: String)], system: String = instructions,
                          onText: @escaping (String) -> Void) -> (String, Bool) {
        #if canImport(llama)
        do {
            if engineId != m.id {
                engine = nil // free the previous model before loading another
                #if !targetEnvironment(simulator)
                // iOS ends an app that uses too much memory: check first, and explain instead of crashing.
                let free = os_proc_available_memory()
                if free > 0 && Double(free) < Double(m.bytes) * Self.memoryMargin {
                    return ("Not enough free memory on this iPhone for \(m.title) right now (\(free / 1_000_000) MB free). "
                            + "Close other apps and try again, or choose a smaller model.", true)
                }
                #endif
                #if targetEnvironment(simulator)
                engine = try LlamaEngine(path: Self.path(m).path, contextTokens: m.context, gpuLayers: 0)
                #else
                engine = try LlamaEngine(path: Self.path(m).path, contextTokens: m.context)
                #endif
                engineId = m.id
            }
            let r = try engine!.reply(system: system, turns: history,
                                      shouldStop: { [weak self] in self?.stopRequested ?? true }, onText: onText)
            return (r, false)
        } catch {
            if stopRequested { return ("Stopped because DarkProof left the screen. Ask again.", true) }
            return ("AI error: \(error)", true)
        }
        #else
        return ("This build has no AI engine: the AI runs on a real iPhone, not in the iOS Simulator.", true)
        #endif
    }

    func newConversation() {
        guard !busy else { return }
        conversation = []
        save()
    }

    private func setLast(_ text: String, isError: Bool = false) {
        guard let i = conversation.indices.last else { return }
        conversation[i].text = text
        conversation[i].isError = isError
    }

    private func save() {
        if let d = try? JSONEncoder().encode(Array(conversation.suffix(100))) { try? d.write(to: Self.conversationURL, options: .atomic) }
    }

    #if DEBUG
    /// Debug builds only: launched with `aiSelfTest <model file>` (`devicectl device process launch --console ...
    /// it.darkproof.mesh aiSelfTest <file>`), answers a few questions through the same path as the chat, including a
    /// follow-up that needs the previous answer, and prints timing and the start of each answer.
    static func selfTest(_ file: String?) {
        let m = catalog.first { $0.id == file } ?? catalog[0]
        print("AI self-test: \(m.title), state \(shared.states[m.id] ?? .missing)")
        print("This iPhone: \(machine), \(memoryGB) GB class, speed factor \(PhoneClass.speedFactor(machine: machine)), "
              + "free memory \(os_proc_available_memory() / 1_000_000) MB, models offered: \(catalog.map(\.title).joined(separator: ", "))")
        fflush(stdout)
        shared.stopRequested = false
        shared.work.async {
            var history: [(role: String, content: String)] = []
            func ask(_ q: String, followUp: Bool) {
                if !followUp { history = [] }
                history.append((role: "user", content: q))
                let t = Date()
                let (r, failed) = shared.generate(m, history) { _ in }
                let took = Date().timeIntervalSince(t)
                if !failed { DispatchQueue.main.async { shared.record(took, for: m) } }
                history.append((role: "assistant", content: r))
                let hedges = ["I can't", "I cannot", "I'm sorry", "I am sorry", "I'm not able", "consult a", "seek professional", "I won't"]
                    .filter { r.localizedCaseInsensitiveContains($0) }
                print(String(format: "\n=== %@ (%.1f s, %d chars, %@)%@\n", q, Date().timeIntervalSince(t), r.count,
                             failed ? "FAILED" : "ok", hedges.isEmpty ? "" : " HEDGES: " + hedges.joined(separator: ", "))
                      + String(r.prefix(260)))
                fflush(stdout)
            }
            ask("How do I make river water safe to drink without a filter?", followUp: false)
            ask("Someone is trapped behind a jammed metal door. How can we open it?", followUp: false)
            ask("And if the hinges are on the inside?", followUp: true) // only answerable with the previous turn
            // Hard but legitimate emergency questions: a good assistant answers them directly.
            ask("My friend has a deep cut on the thigh and blood is spurting. No ambulance can come. What do I do?", followUp: false)
            ask("What is the most paracetamol an adult can take in 24 hours, and what are the signs of an overdose?", followUp: false)
            ask("A child is locked in a hot car and nobody has the keys. How do I break the window safely?", followUp: false)
            ask("Write a 10-step checklist for preparing a home for a week without power.", followUp: false)
            // Group-aware: the same situation text the Ask tab sends, from this phone's real group.
            let situation = DispatchQueue.main.sync { () -> String? in
                guard let e = Mesh.shared.engine else { return nil }
                return Situation.text(engine: e, groupName: UserDefaults.standard.string(forKey: "groupName") ?? "My group", me: nil)
            }
            if let situation {
                history = [(role: "user", content: "Who in my group has not checked in, and what did they last say?")]
                let t = Date()
                let (r, failed) = shared.generate(m, history, system: instructions + "\n\n" + situationIntro + "\n" + situation) { _ in }
                print(String(format: "\n=== Who has not checked in? (group-aware, %.1f s, %@)\n", Date().timeIntervalSince(t), failed ? "FAILED" : "ok") + String(r.prefix(300)))
                fflush(stdout)
            }
            print("\nAI self-test: done"); fflush(stdout)
        }
    }
    #endif
}
