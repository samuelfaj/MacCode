import Foundation

/// Word-overlap test for "is this request the same job as that one". No model call, never blocks:
/// callers only warn. Covers English, Portuguese and Spanish stopwords; other scripts compare as raw words.
public enum DuplicateWorkDetector {
    /// Jaccard score two word sets need to count as the same job.
    public static let threshold = 0.6
    /// Shared words needed unless both sets are identical, so "fix bug" never matches "fix payment bug".
    public static let minSharedWords = 3
    /// Runs and conversations older than this are not compared.
    public static let lookback: TimeInterval = 24 * 60 * 60

    public static func words(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var result = Set<String>()
        var current = ""
        func flush() {
            defer { current = "" }
            guard current.count >= 2, !stopwords.contains(current) else { return }
            var word = current
            // Plural folding: tests/testes/pruebas match test/teste/prueba.
            if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { word.removeLast() }
            if !stopwords.contains(word) { result.insert(word) }
        }
        for character in folded {
            if character.isLetter || character.isNumber { current.append(character) } else { flush() }
        }
        flush()
        return result
    }

    public static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }

    /// Score in 0...1 when the two word sets pass the threshold and the shared-word floor, else nil.
    public static func score(_ a: Set<String>, _ b: Set<String>) -> Double? {
        let shared = a.intersection(b).count
        let value = jaccard(a, b)
        guard value >= threshold else { return nil }
        guard shared >= minSharedWords || (a == b && a.count >= 2) else { return nil }
        return value
    }

    public static func score(_ a: String, _ b: String) -> Double? {
        score(words(a), words(b))
    }

    public static func isSimilar(_ a: String, _ b: String) -> Bool { score(a, b) != nil }

    /// Best score of `request` against a candidate described by title and first request: the title alone,
    /// the first request alone and both together, since a generated title is short and a request is long.
    public static func score(request: String, candidateTitle: String?, candidateRequest: String?) -> Double? {
        let wanted = words(request)
        let title = candidateTitle.map(words) ?? []
        let first = candidateRequest.map(words) ?? []
        return [title, first, title.union(first)].compactMap { score(wanted, $0) }.max()
    }

    private static let stopwords: Set<String> = {
        let english = """
        a an the and or but if then else of to in on at by for with from as is are was were be been being am do does did \
        done doing have has had having it its this that these those there here i me my we us our you your he she they them \
        his her their not no yes can could should would will shall may might must please pls just also so than too very \
        about into over under up down out off again more most some any all each other such only own same what which who \
        whom whose when where why how let lets need needs want wants like make makes use using get gets new
        """
        let portuguese = """
        o os um uma uns umas de do da dos das em no na nos nas por pelo pela pelos pelas para pra com sem sob sobre entre \
        e ou mas se que qual quais quando onde como porque eu me meu minha meus minhas nos nosso nossa voce voces seu sua \
        seus suas ele ela eles elas isso isto esse essa esses essas este esta estes estas aquele aquela ser sao era foi \
        estar esta estao tem tenho ter fazer faz faca favor preciso precisa quero quer pode podem deve devem mais menos \
        muito muita ja so tambem ao aos as la ai ali aqui
        """
        let spanish = """
        el la los las un una unos unas de del al en con sin sobre entre por para y o pero si que cual cuales cuando donde \
        como porque yo mi mis tu tus nosotros nuestro nuestra usted ustedes su sus el ella ellos ellas eso esto ese esa \
        esos esas este esta estos estas aquel aquella ser son era fue estar esta estan tiene tengo tener hacer hace haz \
        favor necesito necesita quiero quiere puede pueden debe deben mas menos muy ya solo tambien lo le les se me te \
        aqui alli
        """
        return Set((english + " " + portuguese + " " + spanish).split(whereSeparator: \.isWhitespace).map(String.init))
    }()
}
