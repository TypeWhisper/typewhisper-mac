#!/usr/bin/env python3
"""Writes corpus.json and questions.json, the synthetic History and the
questions of HistoryRetrievalEvaluationTests.

Usage: make_corpus.py <output directory>

The first records are written by hand and carry the facts the questions ask
for. The others are filler from sentence pools with a fixed seed, so every run
writes the same files.
"""
import json
import random
import sys

APPS = {
    "Slack": "com.tinyspeck.slackmacgap",
    "Mail": "com.apple.mail",
    "Notes": "com.apple.Notes",
    "Safari": "com.apple.Safari",
    "Chrome": "com.google.Chrome",
    "Pages": "com.apple.iWork.Pages",
    "Xcode": "com.apple.dt.Xcode",
    "WhatsApp": "net.whatsapp.WhatsApp",
    "Word": "com.microsoft.Word",
}

records = []


def add(days, time, source, language, text=None, turns=None, title=None, app=None, domain=None, result=None,
        result_title=None):
    record = {"id": f"r{len(records) + 1:03d}", "daysAgo": days, "time": time, "source": source,
              "language": language}
    if title:
        record["title"] = title
    if app:
        record["app"] = app
        record["bundleID"] = APPS[app]
    if domain:
        record["domain"] = domain
    if text:
        record["text"] = text
    if turns:
        record["turns"] = [[speaker, line] for speaker, line in turns]
    if result:
        record["result"] = result
    if result_title:
        record["resultTitle"] = result_title
    records.append(record)
    return record["id"]


A = {}

# --- Anchors: German ---------------------------------------------------------
A["druckerei"] = add(3, "14:05", "recorder", "de", title="Kick-off Druckerei Müller", turns=[
    ("Anna", "Danke, dass ihr alle da seid. Ich bestelle 200 Plakate bis Donnerstag bei der Druckerei Müller, die Vorlage ist seit gestern freigegeben."),
    ("Ben", "Die Flyer brauchen wir erst zur Messe im Januar. Das Format bleibt A5, und wir drucken diesmal auf Recyclingpapier."),
    ("Carla", "Das Budget für den Druck liegt bei 1.800 Euro. Mehr gibt die Geschäftsführung in diesem Quartal nicht frei."),
    ("Anna", "Dann lassen wir die Aufkleber weg. Ben, kannst du bei der Druckerei nachfragen, ob sie die Plakate direkt an den Messebauer liefern?"),
    ("Ben", "Mache ich. Ich frage auch nach einem Probedruck, damit die Farben stimmen. Beim letzten Mal war das Blau viel zu dunkel."),
    ("Carla", "Bitte denkt an die Rechnungsadresse, die hat sich geändert. Die Buchhaltung sitzt jetzt in der Lindenstraße 14."),
    ("Anna", "Gut. Nächster Termin ist in zwei Wochen, bis dahin sollte der Probedruck da sein und wir entscheiden über die Auflage der Flyer."),
    ("Ben", "Eine Sache noch: Der Messebauer braucht die Maße der Rückwand bis Ende des Monats, sonst wird der Aufbau teurer."),
    ("Carla", "Die Maße schicke ich ihm morgen. Drei Meter breit und zwei Meter fünfzig hoch, wie im letzten Jahr."),
])
A["release"] = add(1, "09:12", "mac", "de", app="Slack", text="Kurzes Update an das Team: Der Release von Version 2.4 verschiebt sich auf nächsten Dienstag, weil der Login-Fehler auf Android noch nicht behoben ist. Die Testgruppe bekommt heute Abend einen neuen Build.")
A["heizung"] = add(1, "17:40", "mac", "de", app="Mail", text="Sehr geehrter Herr Brandt, die Heizung im Wohnzimmer fällt seit drei Tagen immer wieder aus. Bitte schicken Sie einen Handwerker, am besten vormittags. Mit freundlichen Grüßen")
A["einkauf"] = add(5, "08:30", "iPhone", "de", text="Einkaufsliste für Samstag: Hafermilch, Parmesan, Zitronen, Backpapier und Geschenkpapier für Lenas Geburtstag.")
A["elternabend"] = add(8, "19:30", "recorder", "de", title="Elternabend Klasse 3b", turns=[
    ("Frau Keller", "Die Klassenfahrt nach Lüneburg findet im Mai statt und kostet 145 Euro pro Kind. Die Anmeldung muss bis zu den Weihnachtsferien bei mir sein."),
    ("Herr Aydin", "Können die Kinder auch später nachgemeldet werden? Wir wissen noch nicht, ob wir im Mai umziehen."),
    ("Frau Keller", "Bis Ende Januar geht das noch. Außerdem suchen wir Lesepaten für die erste Stunde am Mittwoch."),
    ("Herr Aydin", "Ich kann alle zwei Wochen kommen. Und der Kuchenbasar ist am 28. November, richtig?"),
    ("Frau Keller", "Genau, von zehn bis dreizehn Uhr in der Aula. Der Erlös geht an die Schulbibliothek."),
])
A["blog"] = add(20, "21:10", "mac", "de", app="Notes", text="Idee für den Blog: ein Erfahrungsbericht über drei Monate Arbeiten mit Stehschreibtisch, mit Fotos vom Umbau des Arbeitszimmers.")
A["vertrieb"] = add(15, "10:00", "recorder", "de", title="Quartalsplanung Vertrieb", turns=[
    ("Jonas", "Das Umsatzziel für das erste Quartal liegt bei 420.000 Euro. Das sind acht Prozent mehr als im Vorjahr."),
    ("Miriam", "Mit dem neuen Großkunden Nordwind Logistik ist das machbar. Der Rahmenvertrag wird gerade von der Rechtsabteilung geprüft."),
    ("Tobias", "Die Umstellung des CRM auf HubSpot muss bis Februar fertig sein, sonst verlieren wir die Daten aus dem alten System."),
    ("Jonas", "Und die Messe in Köln? Wer fährt hin?"),
    ("Miriam", "Tobias und ich. Wir brauchen noch Hotelzimmer, die Preise steigen jede Woche."),
    ("Tobias", "Ich buche heute. Außerdem schlage ich vor, die Provision für Neukunden von fünf auf sieben Prozent anzuheben."),
    ("Jonas", "Das bespreche ich mit der Geschäftsführung. Bis zum nächsten Termin habe ich eine Antwort."),
])
A["kinderzahnarzt"] = add(9, "12:15", "iPhone", "de", text="Termin beim Kinderzahnarzt für Emil ist am 19. November um 15:30 Uhr. Versichertenkarte und das gelbe Heft mitbringen.")
A["angebot"] = add(40, "11:20", "mac", "de", app="Mail", text="Angebot an Firma Seidel: 14 Tagessätze zu je 950 Euro für die Migration der Lagerverwaltung, Start frühestens Mitte Januar. Reisekosten werden nach Aufwand berechnet.")
A["blutdruck"] = add(12, "16:05", "recorder", "de", title="Sprachnotiz Arzttermin", text="Sprachnotiz nach dem Arzttermin: Der Blutdruck war 135 zu 85. Dr. Hoffmann empfiehlt weniger Salz und drei Mal pro Woche Ausdauersport. Kontrolle in sechs Wochen, das Rezept für die Tabletten liegt in der Apotheke am Markt.")
A["backoff"] = add(4, "22:02", "mac", "de", app="Safari", domain="github.com", text="Kommentar zum Pull Request: Die Wiederholungslogik sollte exponentielles Backoff verwenden, sonst überlasten wir die Schnittstelle bei einem Ausfall. Bitte auch einen Test für den Timeout ergänzen.")
A["ruderclub"] = add(25, "19:00", "recorder", "de", title="Vereinssitzung Ruderclub", turns=[
    ("Holger", "Das Dach vom Bootshaus muss saniert werden. Der Kostenvoranschlag liegt bei 12.000 Euro."),
    ("Sabine", "Dann müssen wir den Mitgliedsbeitrag anheben. Ich schlage 180 Euro im Jahr vor, bisher sind es 150."),
    ("Holger", "Darüber stimmen wir auf der Hauptversammlung ab. Das Sommerfest ist übrigens am 20. Juni."),
    ("Sabine", "Ich kümmere mich um den Grill und frage die Jugendabteilung wegen der Tombola."),
])
A["knie"] = add(2, "07:55", "keyboard", "de", app="WhatsApp", text="Ich schaffe es heute nicht zum Training, mein Knie tut seit dem Lauf am Sonntag weh.")
A["rouladen"] = add(60, "18:20", "iPhone", "de", text="Rezept von Oma Gerda für Rouladen: Senf, Speck, Gewürzgurken und Zwiebeln einrollen, zwei Stunden schmoren und die Soße mit Rotwein ablöschen.")
A["jourfixe"] = add(10, "09:30", "recorder", "de", title="Jour fixe Entwicklung", turns=[
    ("Lukas", "Den Umstieg auf Swift 6 machen wir erst nach dem Release, vorher ist das Risiko zu groß."),
    ("Nina", "Einverstanden. Ich habe übrigens das Speicherleck im Audio-Puffer gefunden, der Ringpuffer wurde nie freigegeben."),
    ("Farid", "Sehr gut. Die Testabdeckung der Synchronisierung liegt jetzt bei 80 Prozent, es fehlen noch die Konfliktfälle."),
    ("Lukas", "Die Konfliktfälle übernimmt Nina. Farid, du schaust dir bitte die Absturzberichte aus der Beta an."),
    ("Farid", "Mache ich. Die meisten Abstürze kommen von einem einzigen Gerät mit einem alten Betriebssystem."),
])
A["bewerbung"] = add(33, "20:45", "mac", "de", app="Pages", text="Bewerbungsanschreiben: Seit acht Jahren leite ich Projekte im Maschinenbau, zuletzt die Einführung einer neuen Fertigungslinie in Stuttgart. Besonders reizt mich an Ihrer Stelle die internationale Ausrichtung.")
A["nebenkosten"] = add(7, "13:10", "iPhone", "de", text="Der Vermieter hat angerufen: Die Nebenkostenabrechnung kommt im Dezember, wir bekommen voraussichtlich 230 Euro zurück.")
A["interview"] = add(45, "15:00", "recorder", "de", title="Interview Hausarzt-Studie", turns=[
    ("Interviewerin", "Wie lange warten Sie im Schnitt auf einen Termin bei Ihrem Hausarzt?"),
    ("Teilnehmer", "Meistens zwei bis drei Wochen. Für eine Krankschreibung rufe ich inzwischen die Videosprechstunde an."),
    ("Interviewerin", "Nutzen Sie das E-Rezept über die App Ihrer Krankenkasse?"),
    ("Teilnehmer", "Ja, das klappt gut. Nur meine Mutter kommt damit nicht zurecht, sie holt den Ausdruck weiter in der Praxis ab."),
])
A["brandschutz"] = add(22, "11:00", "iPad", "de", text="Notizen zur Fortbildung Brandschutz: Feuerlöscher alle zwei Jahre prüfen lassen. Fluchtwege dürfen nicht mit Kartons zugestellt sein, und jede Etage braucht zwei Ersthelfer.")
A["sofa"] = add(16, "10:35", "mac", "de", app="Mail", text="Reklamation an den Möbelhändler: Das gelieferte Sofa hat einen Riss an der linken Armlehne. Ich bitte um Austausch oder einen Preisnachlass von 15 Prozent.")
A["hochzeit"] = add(50, "20:00", "recorder", "de", title="Hochzeitsplanung", turns=[
    ("Julia", "Für die Feier nehmen wir Gut Sonnenhof. Es passen 85 Gäste in den Saal, und draußen ist Platz für die Trauung."),
    ("Stefan", "Das Catering sollte komplett vegetarisch sein, das war dir wichtig. Die Fotografin kostet 2.400 Euro für den ganzen Tag."),
    ("Julia", "Das ist in Ordnung. Der Termin steht: 12. September. Die Einladungen gehen im Februar raus."),
    ("Stefan", "Dann fehlt nur noch die Band. Mein Cousin spielt in einer, ich frage ihn am Wochenende."),
])
A["betriebsrat"] = add(11, "14:00", "windows", "de", text="Protokoll Betriebsrat: Die Kernarbeitszeit wird auf 10 bis 15 Uhr verkürzt. Homeoffice bleibt bei drei Tagen pro Woche, die Regelung gilt ab Januar.")
A["parkhaus"] = add(1, "08:05", "appleWatch", "de", text="Auto steht im Parkhaus am Bahnhof, Ebene 3, Platz 47.")
A["steuer"] = add(6, "09:50", "mac", "de", app="Notes", text="Steuerberaterin Frau Lindner braucht bis Ende November die Belege für das Arbeitszimmer und die Fahrtkosten. Die Spendenquittungen liegen im blauen Ordner.")
A["suedtirol"] = add(75, "21:30", "mac", "de", app="Notes", text="Urlaubsplanung: zwei Wochen Südtirol im August. Die Ferienwohnung in Meran kostet 1.350 Euro, die Anzahlung ist bis Ende März fällig.")
A["garantie"] = add(120, "12:40", "mac", "de", app="Notes", text="Garantie Waschmaschine: gekauft am 14. Juli bei Elektro Krüger, fünf Jahre Garantie, Rechnungsnummer 88213.")
A["marketing"] = add(2, "11:00", "recorder", "de", title="Budgetrunde Marketing", turns=[
    ("Carla", "Wir wechseln das Newsletter-Tool. Brevo kostet die Hälfte und kann die Segmente aus dem Shop übernehmen."),
    ("Ben", "Der Messestand ist mit 9.500 Euro der größte Posten. Können wir die Fläche verkleinern?"),
    ("Anna", "Nein, die Fläche bleibt. Dafür streichen wir das Podcast-Sponsoring, das hat kaum Anmeldungen gebracht."),
    ("Carla", "Einverstanden. Das frei gewordene Geld geht in Suchanzeigen für das Frühjahr."),
])
A["nordwind"] = add(8, "15:25", "mac", "de", app="Slack", text="Der Kunde Nordwind möchte die Schnittstelle zur Zollabwicklung schon im Dezember testen. Bitte plant dafür zwei Personen aus dem Backend ein.")
A["windeln"] = add(3, "17:15", "keyboard", "de", app="WhatsApp", text="Kannst du bitte Milch und Windeln Größe 4 mitbringen, wir haben nichts mehr.")
A["fitness"] = add(27, "19:45", "mac", "de", app="Mail", text="Kündigung Fitnessstudio: Hiermit kündige ich meine Mitgliedschaft Nummer 55120 fristgerecht zum 31. Dezember. Bitte bestätigen Sie mir den Eingang schriftlich.")
A["band"] = add(35, "22:15", "recorder", "de", title="Bandprobe", text="Setliste für den Auftritt im Jazzkeller: Wir starten mit Blue Bossa, das neue Stück von Miriam kommt an dritter Stelle. Die Zugabe ist Autumn Leaves, und der Soundcheck beginnt um 18 Uhr.")
A["ableser"] = add(65, "08:45", "mac", "de", app="Notes", text="Der Heizungsableser kommt am Dienstag zwischen 8 und 12 Uhr. Schlüssel bei Familie Yilmaz im zweiten Stock abgeben.")
A["buchtipp"] = add(17, "13:30", "iPhone", "de", text="Buchtipp von Katrin: Die Vermessung der Welt von Daniel Kehlmann, soll ich unbedingt im Urlaub lesen.")
A["praktikant"] = add(5, "16:20", "mac", "de", app="Slack", text="Feedback an unseren Praktikanten: Die Präsentation war klar aufgebaut, aber die Diagramme brauchen eine größere Schrift und Quellenangaben.")
A["podcast"] = add(19, "10:10", "recorder", "de", title="Planung Podcast Folge 12",
                   text="Also ich denke, wir sollten den Gast viel früher vorstellen, nicht erst nach dem langen Intro. Und die Werbung, hm, die nervt mittendrin, die packen wir ans Ende. Aufnehmen können wir am Vierundzwanzigsten im Studio B, da ist noch frei.",
                   result="Entscheidungen\n- Gastvorstellung in den ersten zwei Minuten\n- Werbeblock nur am Schluss der Folge\n- Aufzeichnung am 24. November im Studio B",
                   result_title="Besprechungsnotizen Podcast")
A["steuerbuero"] = add(4, "09:05", "mac", "de", app="Mail",
                       text="schreib dem Steuerbüro dass die fehlenden Unterlagen nächste Woche kommen und dass ich mich für die Verspätung entschuldige",
                       result="Sehr geehrte Frau Lindner,\n\ndie fehlenden Unterlagen sende ich Ihnen in der kommenden Woche zu. Bitte entschuldigen Sie die Verzögerung.\n\nMit freundlichen Grüßen")
A["umzug"] = add(85, "18:00", "mac", "de", app="Notes", text="Umzug Checkliste: Nachsendeauftrag bei der Post stellen, Strom und Internet ummelden, Transporter für den 3. Oktober reservieren und die Kaution vom alten Vermieter zurückfordern.")
A["fahrrad"] = add(38, "12:00", "iPhone", "de", text="Das Fahrrad ist in der Werkstatt Radwerk am Hafen. Neue Bremsbeläge und eine Kette, Abholung Freitag ab 16 Uhr, kostet ungefähr 90 Euro.")
A["garten"] = add(150, "10:30", "iPhone", "de", text="Gartenplan für das Frühjahr: Tomaten erst nach den Eisheiligen rauspflanzen, die Himbeeren zurückschneiden und für das Hochbeet neue Erde bestellen.")
A["versicherung"] = add(100, "14:50", "mac", "de", app="Mail", text="An die Haftpflichtversicherung: Am 2. August ist mir beim Besuch bei Freunden ein Rotweinglas auf den Teppich gefallen. Die Schadennummer lautet HV 2291.")
A["vortrag"] = add(13, "09:00", "recorder", "de", title="Vortrag Barrierefreiheit", text="Mitschnitt vom Vortrag: Barrierefreiheit beginnt bei der Tastaturbedienung. Jede Schaltfläche braucht eine Beschriftung für den Screenreader, und der Kontrast von Text sollte mindestens 4,5 zu 1 betragen. Ab Juni gilt dafür das Barrierefreiheitsstärkungsgesetz auch für Onlineshops.")
A["anna_urlaub"] = add(6, "15:10", "recorder", "de", title="Teamrunde", turns=[
    ("Anna", "Ich bin vom 23. Dezember bis zum 6. Januar im Urlaub. Vertretung macht in der Zeit Carla."),
    ("Ben", "Dann verschieben wir die Abnahme der Website auf die zweite Januarwoche."),
    ("Carla", "Passt. Ich brauche vorher noch die Zugangsdaten für das Shopsystem."),
])

# --- Anchors: English --------------------------------------------------------
A["staging"] = add(2, "18:30", "mac", "en", app="Slack", text="Quick heads-up: the staging server will be down tonight between ten and midnight for the database migration. Please finish your test runs before nine.")
A["onboarding"] = add(6, "15:00", "recorder", "en", title="Design review onboarding", turns=[
    ("Priya", "The onboarding flow drops forty percent of users at the permission screen. That is our biggest leak right now."),
    ("Marcus", "Let's move the microphone permission after the first successful dictation. People accept it once they see the value."),
    ("Elena", "I'll have the new illustrations ready by Wednesday. The dark mode versions take one more day."),
    ("Priya", "Good. We also need a skip button on the keyboard tutorial, support gets tickets about it every week."),
    ("Marcus", "I can ship the skip button in the next build. The copy still needs a review from legal."),
])
A["passport"] = add(30, "07:45", "iPhone", "en", text="Reminder to self: renew the passport before March. The appointment at the consulate takes about six weeks to get.")
A["proposal"] = add(18, "16:40", "mac", "en", app="Chrome", domain="docs.google.com", text="The proposal should open with the customer's problem, not with our company history. Cut the second page down to three bullet points and move the pricing table to the appendix.")
A["investor"] = add(13, "17:00", "recorder", "en", title="Investor call", turns=[
    ("Daniel", "Our runway is eighteen months at the current burn. Churn fell to 2.1 percent after the pricing change."),
    ("Sophie", "That's encouraging. What is the hiring plan for next year?"),
    ("Daniel", "Two backend engineers in Lisbon and one designer. We will not open a second office before the next round."),
    ("Sophie", "Please send the updated cap table before the board meeting on the fifteenth."),
])
A["waveform"] = add(3, "23:10", "mac", "en", app="Xcode", text="TODO: the waveform view redraws on every audio buffer. Throttle it to thirty frames per second and reuse the path instead of rebuilding it.")
A["quote"] = add(9, "10:15", "mac", "en", app="Mail", text="Hi Tom, thanks for the quote. We'd like to go ahead with the annual plan for twenty-five seats, starting December first. Could you send the contract to our finance team?")
A["retro"] = add(21, "14:30", "recorder", "en", title="Sprint retro", turns=[
    ("Aisha", "The flaky tests cost us two days this sprint. I want one person on call for the test suite."),
    ("Ben", "Agreed. The pairing sessions on Thursdays worked well, let's keep them."),
    ("Chloe", "Reminder that we have a deploy freeze before Black Friday, nothing goes out after the twentieth."),
])
A["gift"] = add(4, "20:20", "iPhone", "en", text="Gift ideas for Dad's seventieth: a weekend in Edinburgh, a new fly-fishing rod, or the whisky tasting he mentioned.")
A["lecture"] = add(55, "11:05", "mac", "en", app="Word", text="Lecture notes: photosynthesis converts light energy into chemical energy stored in glucose. The Calvin cycle happens in the stroma, the light reactions in the thylakoid membrane.")
A["roadmap"] = add(10, "13:45", "mac", "en", app="Safari", domain="notion.so", text="Roadmap update: offline mode moves to the second quarter, the Windows beta ships in February, and the redesign of the pricing page is cancelled.")
A["landlord"] = add(24, "08:20", "mac", "en", app="Mail", text="Dear Mr. Patel, the dishwasher in the flat has been leaking since Monday. Could you arrange a repair this week? I work from home on Thursday and Friday.")
A["marathon"] = add(42, "06:50", "appleWatch", "en", text="Training log: long run of twenty-eight kilometres along the river, average pace five minutes forty. Left calf felt tight after kilometre twenty.")
A["recipe"] = add(95, "19:10", "iPhone", "en", text="Grandma's lemon drizzle cake: two hundred grams of butter, three eggs, zest of two lemons, bake for forty-five minutes and pour the syrup over while it is still warm.")
A["standup"] = add(1, "09:45", "recorder", "en", title="Daily standup", turns=[
    ("Marcus", "Yesterday I finished the export to Markdown. Today I start on the share extension."),
    ("Priya", "I'm blocked on the App Store review, they rejected the screenshots for the iPad."),
    ("Elena", "I can redo the iPad screenshots this afternoon, send me the rejection note."),
])
A["conference"] = add(70, "12:30", "mac", "en", app="Notes", text="Conference takeaways: the keynote on local language models, a workshop about accessibility audits, and a tip to record customer interviews with consent forms prepared in advance.")
A["insurance"] = add(110, "15:35", "mac", "en", app="Mail", text="To the travel insurance: my suitcase arrived two days late in Lisbon. The claim number is TR 55402, and I attach the receipts for the clothes I had to buy.")
A["workshop"] = add(28, "10:00", "recorder", "en", title="Pricing workshop", turns=[
    ("Sophie", "The annual plan should be two months cheaper than paying monthly. That is what most competitors do."),
    ("Daniel", "And the team tier starts at five seats. Below that people can buy single licences."),
    ("Sophie", "I'd test a student discount of fifty percent in the spring."),
])

# --- Anchors: French and Italian --------------------------------------------
A["lyon"] = add(14, "08:10", "iPhone", "fr", text="Rappel : réserver le train pour Lyon avant vendredi. Le billet aller-retour coûte quatre-vingt-dix euros avec la carte de réduction.")
A["greve"] = add(70, "11:40", "mac", "fr", app="Mail", text="Réunion avec le fournisseur : la livraison des pièces détachées est repoussée à la mi-décembre à cause d'une grève au port de Marseille.")
A["dentiste"] = add(31, "09:20", "iPhone", "fr", text="Rendez-vous chez le dentiste mardi à seize heures, ne pas oublier la carte vitale et la radio de l'année dernière.")
A["idraulico"] = add(28, "07:30", "iPhone", "it", text="Ricordati di chiamare l'idraulico per la perdita sotto il lavandino della cucina, preferibilmente martedì mattina.")
A["fatturato"] = add(90, "16:00", "mac", "it", app="Pages", text="Appunti per la presentazione: il fatturato è cresciuto del dodici per cento grazie ai nuovi clienti in Svizzera. Il prossimo obiettivo è aprire un ufficio a Zurigo.")
A["ricetta"] = add(48, "19:40", "iPhone", "it", text="Ricetta della nonna per il ragù: soffritto di sedano, carota e cipolla, carne macinata mista, un bicchiere di vino rosso e tre ore di cottura a fuoco lento.")

ANCHOR_COUNT = len(records)

# --- Filler records ----------------------------------------------------------
rng = random.Random(20261112)

DE_NAMES = ["Anna", "Ben", "Carla", "Jonas", "Miriam", "Tobias", "Lukas", "Nina", "Farid", "Sabine", "Holger", "Petra", "Oliver", "Heike"]
EN_NAMES = ["Priya", "Marcus", "Elena", "Daniel", "Sophie", "Aisha", "Chloe", "Tom", "Grace", "Liam"]
DE_DAYS = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag"]
EN_DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]

DE_POOLS = {
    "arbeit": [
        "Das Protokoll vom letzten Termin schicke ich heute noch herum.",
        "Bitte tragt eure Stunden bis {day} in die Zeiterfassung ein.",
        "Der Kunde wartet auf eine Rückmeldung zum Zeitplan.",
        "Wir brauchen für das Projekt noch eine Freigabe von der Geschäftsführung.",
        "Die Rechnung für den letzten Monat ist noch offen.",
        "Ich habe den Termin mit {name} auf {day} verschoben.",
        "Das Budget für das nächste Quartal steht noch nicht fest.",
        "Können wir das Thema im nächsten Meeting besprechen?",
        "Die Präsentation für den Kunden ist fast fertig, es fehlen nur die Zahlen.",
        "Der neue Kollege fängt am Ersten an und braucht einen Laptop.",
        "Bitte prüft den Vertrag, bevor wir ihn unterschreiben.",
        "Die Abstimmung mit der Buchhaltung dauert länger als geplant.",
    ],
    "technik": [
        "Der Build schlägt seit heute Morgen auf dem Server fehl.",
        "Ich habe den Fehler in der Anmeldung nachstellen können.",
        "Das Update für die App geht morgen in die Prüfung.",
        "Die Datenbank ist am Wochenende sehr langsam geworden.",
        "Bitte schaut euch den Pull Request von {name} an.",
        "Die Tests laufen lokal durch, nur in der Pipeline nicht.",
        "Wir sollten die Abhängigkeiten vor dem Release aktualisieren.",
        "Das Backup vom {day} ließ sich problemlos einspielen.",
        "Der Speicherverbrauch steigt nach einer Stunde deutlich an.",
        "Die Schnittstelle antwortet manchmal erst nach zehn Sekunden.",
    ],
    "alltag": [
        "Denk bitte daran, den Müll rauszubringen.",
        "Ich bin heute gegen sieben zu Hause.",
        "Das Paket liegt bei den Nachbarn im Erdgeschoss.",
        "Wir müssen noch ein Geschenk für {name} besorgen.",
        "Der Handwerker kommt am {day} zwischen neun und zwölf.",
        "Kannst du die Kinder heute von der Schule abholen?",
        "Die Wäsche hängt noch auf dem Balkon.",
        "Am Wochenende kommen meine Eltern zu Besuch.",
        "Ich habe einen Tisch für vier Personen reserviert.",
        "Der Termin beim Friseur ist am {day} um halb fünf.",
    ],
    "gesundheit": [
        "Ich habe seit gestern Kopfschmerzen und bleibe heute zu Hause.",
        "Der Termin beim Hautarzt wurde auf {day} verlegt.",
        "Die Physiotherapie hat mir zehn Sitzungen verschrieben.",
        "Bitte hol das Rezept in der Praxis ab.",
        "Die Impfung für die Reise muss vier Wochen vorher gemacht werden.",
        "Ich soll die Tabletten morgens und abends nehmen.",
        "Die Krankenkasse übernimmt die Kosten für die Brille nicht.",
    ],
    "finanzen": [
        "Die Überweisung an den Vermieter ist raus.",
        "Der Dauerauftrag für den Strom muss angepasst werden.",
        "Ich habe die Rechnung vom Zahnarzt bei der Versicherung eingereicht.",
        "Das Konto ist diesen Monat ziemlich leer.",
        "Wir sollten den Handyvertrag kündigen und wechseln.",
        "Die Steuererklärung muss bis Ende Juli beim Finanzamt sein.",
        "Der Kredit für das Auto läuft noch zwei Jahre.",
    ],
    "reise": [
        "Der Zug nach Hamburg fährt um 7:42 von Gleis 5.",
        "Das Hotel hat die Buchung für zwei Nächte bestätigt.",
        "Wir brauchen noch einen Mietwagen für die erste Woche.",
        "Der Flug wurde um drei Stunden nach hinten verschoben.",
        "Die Fähre legt nur dienstags und freitags ab.",
        "Ich habe die Reiseunterlagen ausgedruckt und in die Mappe gelegt.",
        "Am {day} fahren wir nach dem Frühstück los.",
    ],
}

EN_POOLS = {
    "work": [
        "I'll send the notes from the last meeting around this afternoon.",
        "Please log your hours by {day}.",
        "The client is waiting for an answer on the timeline.",
        "We still need sign-off from management for the project.",
        "Last month's invoice is still open.",
        "I moved the meeting with {name} to {day}.",
        "The budget for next quarter is not final yet.",
        "Can we discuss this in the next meeting?",
        "The slides for the client are almost done, only the numbers are missing.",
        "The new hire starts on the first and needs a laptop.",
        "Please review the contract before we sign it.",
    ],
    "tech": [
        "The build has been failing on the server since this morning.",
        "I managed to reproduce the bug in the sign-in flow.",
        "The app update goes to review tomorrow.",
        "The database got very slow over the weekend.",
        "Please take a look at the pull request from {name}.",
        "The tests pass locally but not in the pipeline.",
        "We should update the dependencies before the release.",
        "Memory usage climbs noticeably after an hour.",
        "The endpoint sometimes takes ten seconds to answer.",
    ],
    "home": [
        "Please remember to take the bins out.",
        "I'll be home around seven tonight.",
        "The parcel is with the neighbours on the ground floor.",
        "We still need a present for {name}.",
        "The plumber is coming on {day} between nine and twelve.",
        "Can you pick up the kids from school today?",
        "My parents are visiting this weekend.",
        "I booked a table for four.",
    ],
    "money": [
        "The transfer to the landlord has gone out.",
        "I filed the dentist's invoice with the insurance.",
        "We should cancel the phone contract and switch.",
        "The tax return is due at the end of the month.",
        "The car loan runs for two more years.",
    ],
    "travel": [
        "The train to Manchester leaves at 7:42 from platform five.",
        "The hotel confirmed the booking for two nights.",
        "We still need a rental car for the first week.",
        "The flight was pushed back by three hours.",
        "I printed the travel documents and put them in the folder.",
    ],
}

FILLER_SOURCES = ["mac"] * 10 + ["iPhone"] * 4 + ["keyboard"] * 2 + ["iPad", "windows", "appleWatch", "recorder", "recorder"]
FILLER_APPS = ["Slack", "Mail", "Notes", "Safari", "Chrome", "WhatsApp", "Word", None, None]
FILLER_TITLES_DE = ["Wochenplanung", "Abstimmung Projekt", "Teamrunde", "Kundentermin", "Statusrunde"]
FILLER_TITLES_EN = ["Weekly sync", "Project check-in", "Team catch-up", "Client call", "Status update"]


def sentence(pool, names, days):
    return rng.choice(pool).format(name=rng.choice(names), day=rng.choice(days))


while len(records) < 200:
    german = rng.random() < 0.62
    pools, names, days = (DE_POOLS, DE_NAMES, DE_DAYS) if german else (EN_POOLS, EN_NAMES, EN_DAYS)
    topic = rng.choice(sorted(pools))
    count = rng.randint(2, 5)
    lines = []
    while len(lines) < count:
        line = sentence(pools[topic] if rng.random() < 0.8 else pools[rng.choice(sorted(pools))], names, days)
        if line not in lines:
            lines.append(line)
    days_ago = min(int(rng.expovariate(1 / 60)) + 1, 400)
    time = f"{rng.randint(7, 21):02d}:{rng.randint(0, 59):02d}"
    source = rng.choice(FILLER_SOURCES)
    language = "de" if german else "en"
    if source == "recorder":
        speakers = rng.sample(names, 3)
        long_lines = [sentence(pools[rng.choice(sorted(pools))], names, days) for _ in range(rng.randint(8, 22))]
        add(days_ago, time, source, language, title=rng.choice(FILLER_TITLES_DE if german else FILLER_TITLES_EN),
            turns=[(speakers[i % 3], line) for i, line in enumerate(long_lines)])
    elif source == "mac":
        app = rng.choice(FILLER_APPS)
        domain = rng.choice(["github.com", "docs.google.com", "notion.so", "linkedin.com"]) if app in ("Safari", "Chrome") else None
        add(days_ago, time, source, language, text=" ".join(lines), app=app, domain=domain)
    else:
        add(days_ago, time, source, language, text=" ".join(lines), app="WhatsApp" if source == "keyboard" else None)

# --- Questions ---------------------------------------------------------------
questions = []


def ask(question, expected, kind="lookup", platform=None):
    entry = {"question": question, "expected": [A[key] for key in expected], "kind": kind}
    if platform:
        entry["platform"] = platform
    questions.append(entry)


# Words of the recording.
ask("Wie viele Plakate bestellt Anna bei der Druckerei?", ["druckerei"])
ask("Was kostet die Klassenfahrt nach Lüneburg?", ["elternabend"])
ask("Wann ist der Kuchenbasar?", ["elternabend"])
ask("Wie hoch ist das Umsatzziel für das erste Quartal?", ["vertrieb"])
ask("Bis wann muss das CRM auf HubSpot umgestellt sein?", ["vertrieb"])
ask("Was hat Dr. Hoffmann empfohlen?", ["blutdruck"])
ask("Wie war mein Blutdruck?", ["blutdruck"])
ask("Was kostet die Sanierung vom Dach des Bootshauses?", ["ruderclub"])
ask("Welche Zutaten gehören in die Rouladen von Oma Gerda?", ["rouladen"])
ask("Wo steht das Auto im Parkhaus?", ["parkhaus"])
ask("Welche Belege braucht die Steuerberaterin?", ["steuer"])
ask("Was kostet die Ferienwohnung in Meran?", ["suedtirol"])
ask("Wie lautet die Rechnungsnummer der Waschmaschine?", ["garantie"])
ask("Wie viele Gäste passen in den Saal von Gut Sonnenhof?", ["hochzeit"])
ask("Was kostet die Fotografin für die Hochzeit?", ["hochzeit"])
ask("Welches Buch hat Katrin empfohlen?", ["buchtipp"])
ask("Wo muss ich den Schlüssel für den Heizungsableser abgeben?", ["ableser"])
ask("Mit welchem Stück starten wir im Jazzkeller?", ["band"])
ask("Wie viele Tagessätze stehen im Angebot an Firma Seidel?", ["angebot"])
ask("Wann ist die Aufzeichnung der Podcast-Folge?", ["podcast"])
ask("Welche Schadennummer hat der Fall mit dem Rotweinglas?", ["versicherung"])
ask("Wo ist das Speicherleck im Audio-Puffer?", ["jourfixe"])
ask("Ab wann gilt das Barrierefreiheitsstärkungsgesetz für Onlineshops?", ["vortrag"])
ask("Was muss ich zum Kinderzahnarzt mitbringen?", ["kinderzahnarzt"])
ask("Wie viel bekommen wir aus der Nebenkostenabrechnung zurück?", ["nebenkosten"])
ask("Auf welche Zeit wird die Kernarbeitszeit verkürzt?", ["betriebsrat"])
ask("Why will the staging server be down tonight?", ["staging"])
ask("Where do users drop out of the onboarding flow?", ["onboarding"])
ask("When does the passport need to be renewed?", ["passport"])
ask("How long is our runway?", ["investor"])
ask("How many seats are in the annual plan for Tom?", ["quote"])
ask("What should the waveform view be throttled to?", ["waveform"])
ask("What were the gift ideas for Dad's seventieth?", ["gift"])
ask("Where does the Calvin cycle happen?", ["lecture"])
ask("When does the Windows beta ship?", ["roadmap"])
ask("What is the claim number for the late suitcase?", ["insurance"])
ask("How long does the lemon drizzle cake bake?", ["recipe"])
ask("What student discount does Sophie want to test?", ["workshop"])
ask("Combien coûte le billet de train pour Lyon ?", ["lyon"])
ask("Pourquoi la livraison des pièces détachées est-elle repoussée ?", ["greve"])
ask("Perché devo chiamare l'idraulico?", ["idraulico"])
ask("Di quanto è cresciuto il fatturato?", ["fatturato"])

# Other word forms, compounds and spellings.
ask("Was wurde zu den Plakaten und Flyern beschlossen?", ["druckerei"], "forms")
ask("Wann ist der Zahnarzttermin von Emil?", ["kinderzahnarzt"], "forms")
ask("Was stand im Kommentar zur Wiederholung bei Ausfällen?", ["backoff"], "forms")
ask("Was habe ich dem Moebelhaendler geschrieben?", ["sofa"], "forms")
ask("Wer vertritt Anna waehrend ihres Urlaubs?", ["anna_urlaub"], "forms")
ask("Welche Mitgliedsnummer hat mein Fitnessstudio-Vertrag?", ["fitness"], "forms")
ask("Was mache ich mit den Tomaten und Himbeeren im Garten?", ["garten"], "forms")
ask("Wann kann ich das Rad aus der Werkstatt holen?", ["fahrrad"], "forms")
ask("Was steht auf der Liste für den Umzug?", ["umzug"], "forms")
ask("Wie lange wartet der Teilnehmer auf Arzttermine?", ["interview"], "forms")
ask("Which tests were flaky in the sprint?", ["retro"], "forms")
ask("What did the landlord need to repair in the flat?", ["landlord"], "forms")
ask("What were my takeaways from the conference keynote?", ["conference"], "forms")
ask("How far was my long run by the river?", ["marathon"], "forms")
ask("What is blocking Priya in the App Store review?", ["standup"], "forms")

# Other words than the recording: full text is not expected to find most of these.
ask("Was habe ich über höhenverstellbare Tische notiert?", ["blog"], "meaning")
ask("Warum gehe ich nicht zum Sport?", ["knie"], "meaning")
ask("Was soll ich aus dem Supermarkt für das Baby mitbringen?", ["windeln"], "meaning")
ask("Welche Rückmeldung habe ich dem Werkstudenten zu seinen Folien gegeben?", ["praktikant"], "meaning")
ask("Wann kommt jemand wegen der kaputten Wärme im Wohnzimmer?", ["heizung"], "meaning")
ask("What did we decide about the price of yearly subscriptions?", ["workshop"], "meaning")
ask("Who is going to redo the tablet images for the store?", ["standup"], "meaning")
ask("What did I write about fixing the kitchen appliance?", ["landlord"], "meaning")
ask("What was decided about posters for the trade fair?", ["druckerei"], "meaning")
ask("Which book should I read on holiday?", ["buchtipp"], "meaning")
ask("Wie viel Geld gibt die Chefetage für Drucksachen frei?", ["druckerei"], "meaning")
ask("Wann fahren die Drittklässler weg und wie teuer wird das?", ["elternabend"], "meaning")
ask("Was hat der Arzt zu meiner Ernährung und Bewegung gesagt?", ["blutdruck"], "meaning")
ask("Wann läuft mein Sportvertrag aus?", ["fitness"], "meaning")
ask("Wo habe ich mein Fahrzeug abgestellt?", ["parkhaus"], "meaning")
ask("Was brauche ich für das Schmorgericht meiner Großmutter?", ["rouladen"], "meaning")
ask("How long does our money last according to the investor update?", ["investor"], "meaning")
ask("Which part of the sign-up loses the most people?", ["onboarding"], "meaning")
ask("From when on may nothing be shipped?", ["retro"], "meaning")
ask("How much does the trip to South Tyrol cost?", ["suedtirol"], "meaning")
ask("What did Anna order from the print shop?", ["druckerei"], "meaning")

# Periods.
ask("Was habe ich gestern in Slack geschrieben?", ["release"], "period", "mac")
ask("Was habe ich gestern über den Release gesagt?", ["release"], "period")
ask("Was wurde letzte Woche beim Elternabend besprochen?", ["elternabend"], "period")
ask("Welche Termine habe ich letzte Woche notiert?", ["kinderzahnarzt"], "period")
ask("Was wurde am Montag über das Budget gesagt?", ["druckerei"], "period")
ask("Was haben wir vorgestern zum Newsletter entschieden?", ["marketing"], "period")
ask("Was habe ich im Oktober über ein Angebot diktiert?", ["angebot"], "period")
ask("What did Marcus say yesterday?", ["standup"], "period")
ask("What did we discuss about onboarding last week?", ["onboarding"], "period")
ask("What did I note about the server two days ago?", ["staging"], "period")

# People.
ask("Was hat Carla zum Budget gesagt?", ["druckerei", "marketing"], "people")
ask("Was hat Farid zu den Abstürzen gesagt?", ["jourfixe"], "people")
ask("Was hat Frau Keller über die Lesepaten gesagt?", ["elternabend"], "people")
ask("Was schlägt Tobias zur Provision vor?", ["vertrieb"], "people")
ask("What did Elena promise for Wednesday?", ["onboarding"], "people")
ask("What did Chloe say about the deploy freeze?", ["retro"], "people")
ask("What did Daniel say about hiring?", ["investor"], "people")

# Apps, domains and devices: only the Mac stores them.
ask("Was habe ich auf github.com zum Pull Request geschrieben?", ["backoff"], "place", "mac")
ask("What did I dictate in Xcode about redrawing?", ["waveform"], "place", "mac")
ask("Was habe ich auf der Watch zum Parkhaus notiert?", ["parkhaus"], "place", "mac")
ask("Was habe ich in Mail an Herrn Brandt geschrieben?", ["heizung"], "place", "mac")
ask("What did I write on notion.so about the roadmap?", ["roadmap"], "place", "mac")
ask("Was steht im Protokoll, das ich unter Windows diktiert habe?", ["betriebsrat"], "place", "mac")

out = sys.argv[1]
with open(f"{out}/corpus.json", "w") as file:
    json.dump({"referenceDate": "2026-11-12T10:00:00+01:00", "timeZone": "Europe/Berlin", "records": records},
              file, ensure_ascii=False, indent=1)
    file.write("\n")
with open(f"{out}/questions.json", "w") as file:
    json.dump(questions, file, ensure_ascii=False, indent=1)
    file.write("\n")
print(f"{len(records)} records ({ANCHOR_COUNT} written by hand), {len(questions)} questions")
