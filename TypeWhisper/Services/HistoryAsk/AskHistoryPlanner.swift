import Foundation
import NaturalLanguage

/// What a search looks for to answer a question.
struct HistorySearchPlan: Equatable, Sendable {
    enum Intent: Sendable {
        /// The question names a topic or a person, which is searched for.
        case lookup
        /// The question only names a part of History ("Summarize last week"),
        /// so the records of that part are read in order.
        case overview
    }

    var question: String
    /// The question's language as an ISO 639 code, when it is clear enough.
    var language: String?
    var keywords: [String] = []
    /// Speakers the question names, as it writes them.
    var names: [String] = []
    /// The period, apps, domains and devices the question names.
    var scope = HistorySearchScope()
    /// The question asks for the last time something came up.
    var prefersNewest = false
    /// The words searched for, counted once each: `keywords` also holds their
    /// dictionary forms.
    var topicCount = 0

    var intent: Intent { keywords.isEmpty && names.isEmpty ? .overview : .lookup }
}

/// Makes a search plan from the words of a question, without a language model.
struct AskHistoryPlanner: Sendable {
    static let maximumKeywords = 24
    static let languageConfidence = 0.6

    /// The speakers, apps and domains of the indexed records.
    var vocabulary = HistorySearchVocabulary()
    var now = Date()
    var calendar = Calendar.current

    func plan(for question: String) -> HistorySearchPlan {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(question)
        let language = recognizer.dominantLanguage?.rawValue
        var plan = HistorySearchPlan(question: question)
        // A short question can be guessed wrong, and a wrong language is worse than none.
        if let dominant = recognizer.dominantLanguage,
           recognizer.languageHypotheses(withMaximum: 1)[dominant, default: 0] >= Self.languageConfidence {
            plan.language = language
        }
        var words = Self.words(of: question, language: language)

        // The words of a period, a domain, an app or a device are not searched for.
        var domains: [(domain: String, ranges: [Range<Int>], isPlaced: Bool)] = []
        let masked = NSMutableString(string: question)
        for domain in vocabulary.domains where !domain.isEmpty {
            // A whole host name: "example.com" is not named in "docs.example.com".
            let pattern = #"(?<![\p{L}\p{N}.-])"# + NSRegularExpression.escapedPattern(for: domain)
                + #"(?![\p{L}\p{N}-]|\.[\p{L}\p{N}])"#
            guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let ranges = expression.matches(in: question, range: NSRange(location: 0, length: masked.length))
                .compactMap { Range($0.range) }
            guard !ranges.isEmpty else { continue }
            let isPlaced = ranges.contains { range in
                words.filter { $0.range.upperBound <= range.lowerBound }.suffix(2)
                    .contains { Self.placeWords.contains($0.folded) }
            }
            domains.append((domain, ranges, isPlaced))
            // "monday.com" names no Monday.
            for range in ranges {
                masked.replaceCharacters(in: NSRange(range), with: String(repeating: " ", count: range.count))
            }
        }
        let period = HistoryPeriodResolver(now: now, calendar: calendar)
            .period(in: masked as String, language: language)
        plan.scope.period = period?.interval
        let used = (period?.utf16Ranges ?? []) + domains.flatMap(\.ranges)
        words.removeAll { word in used.contains { $0.overlaps(word.range) } }

        let apps = vocabulary.apps
            .map { (app: $0, words: HistoryFullTextQuery.words(in: $0.name).map(Self.folded)) }
            .filter { !$0.words.isEmpty }
            .sorted { $0.words.count > $1.words.count }
        let speakerWords = Set(
            vocabulary.speakers
                .map { HistoryFullTextQuery.words(in: $0) }
                // "Speaker 2": a speaker nobody has named.
                .filter { $0.last?.allSatisfy(\.isNumber) == false }
                .flatMap { $0.map(Self.folded) }
                .filter { $0.count >= 2 }
        )
        let stopWords = Self.stopWords(for: language)

        var keywords: [String] = []
        var topics = Set<String>()
        var name: [String] = []
        func finishName() {
            if !name.isEmpty { plan.names.append(name.joined(separator: " ")) }
            name = []
        }
        var index = 0
        while index < words.count {
            let word = words[index]
            let isPlaced = words[max(index - 2, 0)..<index].contains { Self.placeWords.contains($0.folded) }
            if isPlaced, let sources = Self.devices[word.folded] {
                plan.scope.sources.formUnion(sources.map(\.rawValue))
                finishName()
                index += 1
                continue
            }
            if isPlaced, let match = apps.first(where: { app in
                index + app.words.count <= words.count
                    && zip(app.words, words[index...]).allSatisfy { $0 == $1.folded }
            }) {
                // Every app with this name, such as two versions of a browser.
                plan.scope.bundleIDs.formUnion(apps.filter { $0.words == match.words }.map(\.app.bundleID))
                finishName()
                index += match.words.count
                continue
            }
            index += 1
            if speakerWords.contains(word.folded) {
                name.append(word.text)
                continue
            }
            finishName()
            guard word.isContent, !stopWords.contains(word.folded),
                  word.lemma.map({ !stopWords.contains($0) }) ?? true else { continue }
            keywords.append(word.text)
            topics.insert(word.lemma ?? word.folded)
            if let lemma = word.lemma, lemma != word.folded { keywords.append(lemma) }
        }
        finishName()

        for domain in domains {
            // Next to an app, a host named without "on" or "auf" is a topic:
            // what was written in Slack about example.com.
            if domain.isPlaced || plan.scope.bundleIDs.isEmpty {
                plan.scope.domains.insert(domain.domain)
            } else {
                keywords.append(domain.domain)
                topics.insert(Self.folded(domain.domain))
            }
        }
        plan.topicCount = topics.count

        var seen = Set<String>()
        plan.keywords = Array(keywords.filter { seen.insert(Self.folded($0)).inserted }.prefix(Self.maximumKeywords))
        let folded = " " + words.map(\.folded).joined(separator: " ") + " "
        plan.prefersNewest = Self.newestPhrases.contains { folded.contains(" \($0) ") }
        return plan
    }

    /// Whether a model should read the question together with the earlier
    /// conversation: a follow-up that names fewer than two things to search for.
    static func needsFollowUpPlan(_ plan: HistorySearchPlan, history: [AskHistoryTurn]) -> Bool {
        !history.isEmpty && plan.topicCount + plan.names.count < 2
    }

    /// The plan for a follow-up question with what a model read from the
    /// conversation. The period and the places come from the question alone,
    /// because models invent periods.
    func plan(for question: String, followUp: AskHistoryFollowUpPlan) -> HistorySearchPlan {
        var plan = plan(for: question)
        let rewritten = self.plan(for: followUp.question)
        let stopWords = Self.stopWords(for: plan.language ?? rewritten.language)
        var seen = Set<String>()
        plan.keywords = (plan.keywords + rewritten.keywords + followUp.keywords)
            .filter { !stopWords.contains(Self.folded($0)) && seen.insert(Self.folded($0)).inserted }
            .prefix(Self.maximumKeywords)
            .map { $0 }
        for name in rewritten.names where !plan.names.contains(name) {
            plan.names.append(name)
        }
        // Words that are names are searched as names only.
        let names = Set(plan.names.flatMap { $0.split(separator: " ").map { Self.folded(String($0)) } })
        plan.keywords.removeAll { names.contains(Self.folded($0)) }
        return plan
    }

    // MARK: - Words

    private struct Word {
        var text: String
        /// Lowercased and without diacritics.
        var folded: String
        var lemma: String?
        var range: Range<Int>
        /// A word that can name a topic, as opposed to "the", "and" or "with".
        var isContent: Bool
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func words(of question: String, language: String?) -> [Word] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = question
        let whole = question.startIndex..<question.endIndex
        if let language { tagger.setLanguage(NLLanguage(language), range: whole) }

        var words: [Word] = []
        var classes: [NLTag?] = []
        tagger.enumerateTags(
            in: whole, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]
        ) { tag, range in
            let text = String(question[range])
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return true }
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0
                .map { folded($0.rawValue) }
            let utf16 = NSRange(range, in: question)
            words.append(Word(
                text: text, folded: folded(text), lemma: lemma,
                range: utf16.location..<NSMaxRange(utf16), isContent: false
            ))
            classes.append(tag)
            return true
        }

        // Without word classes, as in a language the tagger does not know,
        // words of four letters and more count, which leaves most function words out.
        let hasClasses = classes.contains { $0 != nil && $0 != .otherWord }
        for index in words.indices {
            let length = words[index].text.count
            guard hasClasses, let tag = classes[index] else {
                words[index].isContent = length >= 4
                continue
            }
            switch tag {
            case .noun, .number, .otherWord: words[index].isContent = length >= 2
            case .verb, .adjective: words[index].isContent = length >= 3
            case .adverb: words[index].isContent = length >= 5
            default: break
            }
        }
        return words
    }

    // MARK: - Word lists

    /// Words before an app or a device: "in Slack", "auf dem iPhone".
    private static let placeWords: Set<String> = [
        "in", "im", "auf", "am", "bei", "vom", "von", "mit", "aus", "unter", "on", "at", "from", "via",
        "dans", "sur", "depuis", "avec", "en", "desde", "con", "su", "sul", "sull", "nel", "da", "dal", "dall",
    ]

    private static let devices: [String: Set<RecordingSource>] = [
        "iphone": [.iPhone, .keyboard],
        "ipad": [.iPad],
        "watch": [.appleWatch],
        "windows": [.windows],
        "pc": [.windows],
        "mac": [.mac, .recorder],
        "macbook": [.mac, .recorder],
    ]

    private static let newestPhrases = [
        "last time", "most recent", "latest", "zuletzt", "letzte mal", "letzten mal", "letztes mal",
        "derniere fois", "ultima vez", "ultima volta",
    ]

    /// Words that frame a question about recordings and name no topic: forms of
    /// "be" and "have", "say", "recording", "summarize". The tagger already
    /// leaves out articles, pronouns and prepositions; the longer ones are also
    /// listed for a Mac whose tagger has no word classes for the language.
    private static func stopWords(for language: String?) -> Set<String> {
        guard let language, let words = stopWordsByLanguage[language] else {
            return stopWordsByLanguage.values.reduce(into: Set()) { $0.formUnion($1) }
        }
        return words
    }

    private static let stopWordsByLanguage: [String: Set<String>] = [
        "en": """
            be am is are was were been being have has had having do does did done will would can could \
            should shall may might must say said says saying tell told talk talked talking speak spoke \
            spoken mention mentioned discuss discussed discussion write wrote written dictate dictated \
            note noted record recorded recording recordings transcript transcripts dictation dictations \
            meeting meetings conversation conversations call calls history summarize summarise summary \
            overview recap give show find know remember happen happened thing things something anything \
            time times last latest recent recently not much many more most go going get got make made \
            what when where which who whom whose why how \
            this that these those their theirs them they your yours ours mine with from about into over \
            some there then than also just only very
            """,
        "de": """
            sein bin bist ist sind seid war waren wart gewesen haben habe hast hat habt hatte hatten gehabt \
            werden werde wirst wird werdet wurde wurden geworden worden kann kannst konnen konnte konnten \
            soll sollte sollten muss musste will wollte wollten mochte sagen sage sagt sagte sagten gesagt \
            reden redet geredet sprechen spricht sprach gesprochen besprechen bespricht besprochen erwahnen \
            erwahnt schreiben schrieb geschrieben diktieren diktiert notieren notiert aufnehmen aufgenommen \
            aufnahme aufnahmen transkript transkripte diktat diktate meeting meetings besprechung \
            besprechungen gesprach gesprache verlauf fasse fassen zusammen zusammenfassen zusammenfassung \
            uberblick ubersicht zeig zeige zeigen gib geben finde finden weiss wissen erinnern passiert \
            sache sachen etwas mal zuletzt letzte letzten letztes neueste neuesten kurzlich nicht viel viele mehr \
            kommen kommt gehen geht gehe machen macht gemacht was wer wen wem \
            wann warum wieso weshalb welche welcher welches welchen wofur woruber \
            meine meinen meinem meiner meines deine deinen deinem deiner deines seine seinen seinem seiner \
            seines ihre ihren ihrem ihrer ihres unser unsere unseren unserem unserer euer eure euren eurem \
            diese diesen diesem dieser dieses alle allen aller alles einen einem einer eines dass oder aber \
            noch auch schon uber nach durch gegen ohne zwischen wegen damit sich mich dich euch
            """,
        "fr": """
            etre suis es est sommes etes sont etais etait etaient ete avoir ai as avons avez ont avais \
            avait avaient eu dire dis dit disait parler parle parlait discuter discute mentionner mentionne \
            ecrire ecrit dicter dicte noter note enregistrer enregistre enregistrement enregistrements \
            transcription transcriptions dictee dictees reunion reunions conversation conversations \
            historique resume resumer resumes apercu montre montrer donne donner trouve trouver chose \
            choses fois dernier derniere recemment quoi quel quelle quels quelles quand pourquoi comment \
            notre votre leur leurs nous vous elle elles cette ces avec pour dans sans sous chez entre
            """,
        "es": """
            ser soy eres es somos son era eran sido estar estoy esta estan estaba haber he has ha hemos han \
            habia decir digo dice dijo dije dicho hablar hablo hablamos mencionar menciono comentar \
            escribir escribi escrito dictar dicte dictado anotar grabar grabacion grabaciones \
            transcripcion transcripciones reunion reuniones conversacion conversaciones historial resume \
            resumir resumen muestra mostrar dame dar encuentra encontrar cosa cosas vez ultima ultimo \
            recientemente que cual cuales cuando donde como quien porque \
            nuestro nuestra nuestros nuestras vuestro vuestra ellos ellas este estos estas para \
            sobre entre desde hacia
            """,
        "it": """
            essere sono sei siamo siete era erano stato stata avere ho hai ha abbiamo avete hanno aveva \
            avevano avuto dire dico dice detto parlare parlato discutere discusso menzionare menzionato \
            scrivere scritto dettare dettato annotare registrare registrato registrazione registrazioni \
            trascrizione trascrizioni dettatura riunione riunioni conversazione conversazioni cronologia \
            riassumi riassumere riassunto panoramica mostra mostrare dammi dare trova trovare cosa cose \
            volta ultima ultimo recentemente che quale quali quando dove come perche chi \
            mio mia miei mie tuoi tue suoi sue nostro nostra nostri nostre vostro vostra loro questo \
            questa questi queste quello quella sopra senza tra fra
            """,
    ].mapValues { Set($0.split(separator: " ").map(String.init)) }
}
