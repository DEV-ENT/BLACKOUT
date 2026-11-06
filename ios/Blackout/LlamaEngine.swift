#if canImport(llama) // llama.cpp is linked only into real-iPhone builds (and the Mac test tool), not the Simulator
import Foundation
import llama

/// Runs a GGUF chat model with llama.cpp. The prompt is built with the chat template stored in the model file,
/// so the model gets exactly the format it was trained on. Not thread-safe: call from one queue.
final class LlamaEngine {
    enum Failure: Error, CustomStringConvertible {
        case load, context, template, tooLong(Int), decode(Int32), stopped
        var description: String {
            switch self {
            case .stopped: return "stopped"
            case .load: return "could not load the AI model"
            case .context: return "not enough memory for the AI"
            case .template: return "the model has no usable chat template"
            case .tooLong(let n): return "the question is too long (\(n) tokens)"
            case .decode(let c): return "the AI stopped with error \(c)"
            }
        }
    }

    typealias Turn = (role: String, content: String) // role: "user" or "assistant"
    private static let backend: Void = llama_backend_init()
    let contextTokens: Int32
    private let model: OpaquePointer
    private let vocab: OpaquePointer
    private let template: UnsafePointer<CChar>
    /// Models that can think before answering (Qwen 3.x): their template mentions <think>. Normal answers skip thinking,
    /// which on a phone would take minutes, by starting the reply with an empty think block, as the model's own
    /// template does when thinking is turned off.
    private let thinks: Bool
    private static let batch: Int32 = 512 // tokens per llama_decode call: bigger is faster but needs more memory

    init(path: String, contextTokens: Int32 = 4096, gpuLayers: Int32 = 99) throws {
        _ = Self.backend
        var mp = llama_model_default_params()
        mp.n_gpu_layers = gpuLayers
        guard let m = llama_model_load_from_file(path, mp) else { throw Failure.load }
        guard let t = llama_model_chat_template(m, nil) else { llama_model_free(m); throw Failure.template }
        model = m; vocab = llama_model_get_vocab(m); template = t
        thinks = String(cString: t).contains("<think>")
        self.contextTokens = contextTokens
    }

    deinit { llama_model_free(model) }

    func reply(system: String, user: String, maxTokens: Int32 = 512, onText: (String) -> Void = { _ in }) throws -> String {
        try reply(system: system, turns: [(role: "user", content: user)], maxTokens: maxTokens, onText: onText)
    }

    /// Generates the next assistant turn of a conversation (the last turn is the user's). If the conversation does not
    /// fit the context window, the oldest turns are left out. `onText` gets the whole reply so far after each token;
    /// `shouldStop` is checked before each token (iOS forbids GPU work once the app is in the background).
    func reply(system: String, turns: [Turn], maxTokens: Int32 = 512, shouldStop: () -> Bool = { false },
               onText: (String) -> Void = { _ in }) throws -> String {
        var turns = turns
        var tokens = tokenize(try fullPrompt(system: system, turns: turns))
        while Int32(tokens.count) + maxTokens > contextTokens {
            guard turns.count > 1 else { throw Failure.tooLong(tokens.count) }
            turns.removeFirst(min(2, turns.count - 1)) // forget the oldest question and answer
            tokens = tokenize(try fullPrompt(system: system, turns: turns))
        }

        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(contextTokens)
        cp.n_batch = UInt32(Self.batch)
        cp.n_ubatch = UInt32(Self.batch)
        guard let ctx = llama_init_from_model(model, cp) else { throw Failure.context }
        defer { llama_free(ctx) }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.6))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))

        var rc: Int32 = 0
        for start in stride(from: 0, to: tokens.count, by: Int(Self.batch)) { // the prompt, a batch at a time
            if shouldStop() { throw Failure.stopped }
            let end = min(start + Int(Self.batch), tokens.count)
            rc = tokens[start..<end].withUnsafeBufferPointer { b in
                llama_decode(ctx, llama_batch_get_one(UnsafeMutablePointer(mutating: b.baseAddress), Int32(b.count)))
            }
            guard rc == 0 else { throw Failure.decode(rc) }
        }
        var bytes: [UInt8] = []
        var piece = [CChar](repeating: 0, count: 256)
        for _ in 0..<maxTokens {
            if shouldStop() { throw Failure.stopped }
            var token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if n > 0 {
                bytes += piece[0..<Int(n)].map { UInt8(bitPattern: $0) }
                let text = String(decoding: bytes, as: UTF8.self) // a token can end mid-character; the next completes it
                if let stop = Self.stops.compactMap({ text.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
                    bytes = Array(text[..<stop.lowerBound].utf8); break
                }
                onText(Self.visible(text))
            }
            rc = withUnsafeMutablePointer(to: &token) { llama_decode(ctx, llama_batch_get_one($0, 1)) }
            guard rc == 0 else { throw Failure.decode(rc) }
        }
        return Self.visible(String(decoding: bytes, as: UTF8.self))
    }

    /// The prompt, plus an empty think block for models that would otherwise think first.
    private func fullPrompt(system: String, turns: [Turn]) throws -> String {
        let p = try prompt(system: system, turns: turns)
        return thinks && !p.hasSuffix("</think>\n\n") ? p + "<think>\n\n</think>\n\n" : p
    }

    /// The reply without any thinking: <think>…</think> blocks, or an unfinished one at the end, are left out.
    static func visible(_ text: String) -> String {
        var t = text
        while let open = t.range(of: "<think>") {
            if let close = t.range(of: "</think>", range: open.upperBound..<t.endIndex) { t.removeSubrange(open.lowerBound..<close.upperBound) }
            else { t.removeSubrange(open.lowerBound..<t.endIndex) }
        }
        return t.replacingOccurrences(of: "</think>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// System message and conversation formatted with the model's own chat template, ending where the assistant reply starts.
    func prompt(system: String, turns: [Turn]) throws -> String {
        let all = [(role: "system", content: system)] + turns
        let roles = all.map { strdup($0.role)! }, contents = all.map { strdup($0.content)! }
        defer { (roles + contents).forEach { free($0) } }
        let chat = zip(roles, contents).map { llama_chat_message(role: UnsafePointer($0), content: UnsafePointer($1)) }
        var buf = [CChar](repeating: 0, count: all.reduce(512) { $0 + $1.content.utf8.count * 2 })
        var n = llama_chat_apply_template(template, chat, chat.count, true, &buf, Int32(buf.count))
        if n > Int32(buf.count) {
            buf = [CChar](repeating: 0, count: Int(n) + 1)
            n = llama_chat_apply_template(template, chat, chat.count, true, &buf, Int32(buf.count))
        }
        guard n > 0 else {
            // llama.cpp's built-in formatter doesn't know every new template yet: Gemma 4 is written out by hand,
            // as its own template does it (the BOS token is added when tokenizing).
            if String(cString: template).contains("<|turn>") { return Self.gemma4(all) }
            throw Failure.template
        }
        return String(decoding: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Gemma 4 chat format without thinking: <|turn>role\n…<turn|>\n per message, assistant written as "model",
    /// ending with the start of the model's turn.
    static func gemma4(_ messages: [Turn]) -> String {
        messages.map { "<|turn>\($0.role == "assistant" ? "model" : $0.role)\n\($0.content)<turn|>\n" }.joined() + "<|turn>model\n"
    }

    /// Text that marks the end of a turn but may not be flagged as end-of-generation in every model file.
    private static let stops = ["<turn|>", "<|turn>", "<|im_end|>"]

    private func tokenize(_ text: String) -> [llama_token] {
        let len = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(len) + 8)
        var n = llama_tokenize(vocab, text, len, &tokens, Int32(tokens.count), true, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, len, &tokens, Int32(tokens.count), true, true)
        }
        return Array(tokens.prefix(Int(max(n, 0))))
    }
}
#endif
