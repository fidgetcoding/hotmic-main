import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model (macOS 26 with Apple Intelligence on). No account, no key, nothing leaves the Mac.
/// On older systems, or with Apple Intelligence off, `isAvailable` is false and the rules run.
public struct FoundationLineModel: LineModel {
    public let name = "apple-foundation"
    public init() {}

    static let instructions = """
    You read a speech-recognition transcript of a songwriting session, usually a livestream. An artist writes lyrics out loud over a beat, trying lines again and again, and between tries talks to people in the room or watching. The transcript has mistakes, and words may be garbled. A * is a bleeped word.

    You will get a few lines around one marked line. Decide what the marked line is.
    LYRIC = words meant for the song: imagery, boasts, love and pain, rhymes, flows, the same phrase tried again with small changes, hooks, ad-libs, even if garbled or unfinished.
    TALK = the artist speaking as themselves to someone: about the session, the beat, the viewers, plans, opinions, stories, questions, instructions, greetings, thanks, what they will do next.

    Garbled words with rhythm are usually LYRIC. A plain sentence that explains, asks or plans is TALK, even with swearing.

    Examples:
    "so we gonna run this one more time, turn the beat up" -> TALK
    "thanks for pulling up y'all, what's the name of this beat" -> TALK
    "i like that, hold on, let me try something, chat what y'all think" -> TALK
    "we got five thousand people in here, press one if you want this one" -> TALK
    "pull up in the coupe with the roof gone, moonlight on my new song" -> LYRIC
    "baby i been running through your mind, every single night, every single time" -> LYRIC
    "uh, whip it out the freeway, uh, whip it out the freeway" -> LYRIC
    "stacks on the dash, yeah, bad girl in the back" -> LYRIC

    Answer with one word: LYRIC or TALK.
    """

    /// The marked line with its neighbours.
    static func prompt(before: [String], line: String, after: [String]) -> String {
        var p = ""
        for b in before { p += "  \(b)\n" }
        p += ">> \(line)\n"
        for a in after { p += "  \(a)\n" }
        return p + "\nWhat is the >> line? LYRIC or TALK."
    }

    /// Its answer, or nil for a refusal in words ("I can't help with that") or anything else.
    static func parse(_ reply: String) -> LineVerdict? {
        let answer = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
            .uppercased()
        switch answer {
        case "LYRIC": return .writing
        case "TALK": return .talk
        default: return nil
        }
    }

    public var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    public func judge(before: [String], line: String, after: [String]) async throws -> LineVerdict? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            // Permissive: the default guardrails refuse lyrics before the model reads them. A new session per
            // line, so no line colours the next.
            let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            let session = LanguageModelSession(model: model, instructions: Self.instructions)
            do {
                let reply = try await session.respond(to: Self.prompt(before: before, line: line, after: after),
                                                      options: GenerationOptions(sampling: .greedy, temperature: 0, maximumResponseTokens: 6))
                return Self.parse(reply.content)
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .guardrailViolation, .refusal, .unsupportedLanguageOrLocale: return nil   // garbled words can read as another language
                default: throw error
                }
            }
        }
        #endif
        return nil
    }
}
