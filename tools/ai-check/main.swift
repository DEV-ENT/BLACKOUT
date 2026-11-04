// TEST TOOL, not part of the app. Runs the iPhone app's LlamaEngine.swift on this Mac (llama.cpp macOS build) with
// the same model, to check the chat template, tokenization and generation before trying it on a phone.
// Usage: ai-check <model.gguf>
import Foundation

let system = "You are an offline emergency assistant. Answer in English, briefly. If you are not sure, say so. "
    + "In medical emergencies, follow the instructions of emergency services."
let start = Date()
let engine = try LlamaEngine(path: CommandLine.arguments[1])
print(String(format: "model loaded in %.1f s", Date().timeIntervalSince(start)))

func run(_ label: String, _ user: String) throws {
    let t0 = Date()
    let answer = try engine.reply(system: system, user: user)
    print("\n=== \(label) (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s) ===\n\(answer)")
}

try run("question", "Someone has a deep cut on the arm and it is bleeding a lot. What should I do?")
try run("summary", """
Summarize these emergency messages in English: who is safe, who is asking for help, and what is missing. Do not make anything up.

18:02 Marco: We are all fine at the school, 12 people, no injuries.
18:05 Giulia: My father needs insulin, we have only one day left. Via Roma 14.
18:09 Luca: Water stopped in our building, we have 6 bottles for 4 people.
18:15 Anna: Is anyone near the hospital? We need someone to check on my grandmother.
""")
try run("emoji and accents", "Rispondi in una frase: l'acqua è finita 💧, cosa faccio?")
