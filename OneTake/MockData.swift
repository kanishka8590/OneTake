import SwiftUI
import SwiftData

enum MockData {

    // MARK: - Deterministic Demo IDs

    static let heerRanjhaID = UUID(uuidString: "D0000001-0001-4000-8000-000000000001")!
    static let theLastSummerID = UUID(uuidString: "D0000001-0001-4000-8000-000000000002")!
    static let noahAndAllieID = UUID(uuidString: "D0000002-0001-4000-8000-000000000001")!
    static let nainaID = UUID(uuidString: "D0000002-0001-4000-8000-000000000002")!

    static let demoAuditionIDs: Set<UUID> = [heerRanjhaID, theLastSummerID]
    static let demoScriptIDs: Set<UUID> = [noahAndAllieID, nainaID]

    static func isDemoAudition(_ audition: Audition) -> Bool {
        demoAuditionIDs.contains(audition.id)
    }

    static func isDemoScript(_ script: PracticeScript) -> Bool {
        demoScriptIDs.contains(script.id)
    }

    // MARK: - User Profile

    static var sampleUser: UserProfile {
        let user = UserProfile()
        user.name = "Avery Vance"
        user.email = "demo@onetake.app"
        user.height = "5'8\""
        user.age = 27
        user.basedIn = "Mumbai / New York"
        user.representation = "Bramwell Talent"
        user.previousWork = []
        return user
    }

    // MARK: - Auditions

    static var sampleAuditions: [Audition] {
        [heerRanjha, theLastSummer]
    }

    static var heerRanjha: Audition {
        let a = Audition(id: heerRanjhaID)
        a.projectName = "Heer Ranjha"
        a.productionType = ProductionType.featureFilm.rawValue
        a.roleName = "Heer"
        a.roleDescription = "A fierce young woman torn between family loyalty and forbidden love, set in rural Punjab."
        a.deadline = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
        a.reminderOffsetMinutes = 120
        a.recipientEmail = "casting@dharmaproductions.com"
        a.statusRaw = AuditionStatus.active.rawValue
        a.requirements = [
            SubmissionRequirement(title: "Self-tape", isCompleted: false),
            SubmissionRequirement(title: "Headshot: 4×5 theatrical", isCompleted: true),
            SubmissionRequirement(title: "Slate with name, height, and agency", isCompleted: false),
            SubmissionRequirement(title: "Submit to casting@dharmaproductions.com", isCompleted: false)
        ]
        a.scriptText = """
        HEER
        I won't let them decide my fate. Not my father, not the village, not even God.

        RANJHA
        Then come with me. Tonight.

        HEER
        (beat)
        You think love is that simple? You run and the world just... lets you go? I love you but I can't betray my family. We'll have to convince them anyhow. And I know, together we will.
        """
        a.scriptFileName = "Heer_Ranjha_Sides.pdf"
        a.validationRules = ValidationRules(
            isFromNotice: true,
            requiredHeadshotRatio: .ratio4x5,
            maxSlateSeconds: 30.0,
            maxClipSeconds: 180.0,
            requiredPortrait: false,
            fileNamePattern: "AveryVance_Heer",
            maxPerClipSizeMB: 100.0
        )
        a.cueLines = [
            CueLine(
                orderIndex: 0,
                speaker: "RANJHA",
                cueText: "Then come with me. Tonight.",
                precedingActorLine: "I won't let them decide my fate. Not my father, not the village, not even God."
            )
        ]
        a.createdAt = Calendar.current.date(byAdding: .day, value: -5, to: Date()) ?? Date()
        return a
    }

    static var theLastSummer: Audition {
        let a = Audition(id: theLastSummerID)
        a.projectName = "The Last Summer"
        a.productionType = ProductionType.series.rawValue
        a.roleName = "Meera"
        a.roleDescription = "A college student navigating her final summer before graduation, dealing with love, friendship, and identity."
        a.deadline = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        a.reminderOffsetMinutes = 60
        a.recipientEmail = "auditions@excelfamily.com"
        a.statusRaw = AuditionStatus.active.rawValue
        a.requirements = [
            SubmissionRequirement(title: "1 monologue (under 2 min)", isCompleted: true),
            SubmissionRequirement(title: "1 scene with reader", isCompleted: false),
            SubmissionRequirement(title: "Close-up headshot", isCompleted: true)
        ]
        a.scriptText = """
        MEERA
        Everything is just...ending. I just feel like everything is gonna be over. I'm done at the paper. Soon I'm gonna be done at Yale, and it's just like I'm standing on this cliff, looking out into this huge, foggy...ike, a huge

        ANYA
        you mean abyss?

        MEERA
        foggy abyss, and, in my whole life, there's never been an abyss. It's been abyssless. I've always known exactly what is in front of me, and I've always known exactly where I'm going, and now...I don't know what's out there. A ton of fog, and I hate not knowing what is out there. I mean, what's going to happen to my career and my relationship with Logan and the rest of my life?
        """
        a.scriptFileName = "TheLastSummer_Ep101_Meera.pdf"
        a.validationRules = ValidationRules()
        a.cueLines = [
            CueLine(
                orderIndex: 0,
                speaker: "ANYA",
                cueText: "you mean abyss?",
                precedingActorLine: "Everything is just...ending. I just feel like everything is gonna be over. I'm done at the paper. Soon I'm gonna be done at Yale, and it's just like I'm standing on this cliff, looking out into this huge, foggy...ike, a huge"
            )
        ]
        a.createdAt = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date()
        return a
    }


    // MARK: - Practice Scripts

    static var sampleScripts: [PracticeScript] {
        [noahAndAllie, naina]
    }

    static var noahAndAllie: PracticeScript {
        let s = PracticeScript(id: noahAndAllieID)
        s.title = "Noah & Allie"
        s.languageRaw = ScriptLanguage.english.rawValue
        s.rawText = """
        ALLIE
        We first met at Luke’s, during a crazy lunch rush. You came rushing in, desperate for coffee, interrupting me while I was serving a customer. You wouldn't stop talking, so I finally told you to sit down, shut up, and wait your turn. Then you asked for my birthday, looked up my horoscope, and handed me a piece of paper that said, “You will meet an annoying woman. Give her coffee, and she'll go away.” You told me to keep it in my wallet because one day it would bring me luck.

        NOAH
        And you actually kept it? In your wallet? For eight years?

        ALLIE
        (stunned)
        Eight years

        NOAH
        Yes. It wasn't over. It still isn't over.
        """
        s.cueLines = [
            CueLine(
                orderIndex: 0,
                speaker: "NOAH",
                cueText: "And you actually kept it? In your wallet? For eight years?",
                precedingActorLine: "We first met at Luke’s, during a crazy lunch rush. You came rushing in, desperate for coffee, interrupting me while I was serving a customer. You wouldn't stop talking, so I finally told you to sit down, shut up, and wait your turn. Then you asked for my birthday, looked up my horoscope, and handed me a piece of paper that said, “You will meet an annoying woman. Give her coffee, and she'll go away.” You told me to keep it in my wallet because one day it would bring me luck."
            )
        ]
        s.lastPracticedAt = Calendar.current.date(byAdding: .day, value: -1, to: Date())

        let sampleSession = PracticeSpeechDeliveryAnalyzer.makeSession(
            script: s,
            transcript: "We first met at Luke's during a crazy lunch rush. You came rushing in desperate for coffee interrupting me while I was serving a customer. You would not stop talking so I finally told you to sit down and wait your turn. Then you asked for my birthday looked up my horoscope and handed me a piece of paper that said You will meet an annoying woman. Give her coffee and she will go away. You told me to keep it in my wallet because one day it would bring me luck. Eight years.",
            words: [],
            clueRequestedRanges: [],
            duration: 34,
            help: .gaps,
            audioURL: nil
        )
        s.sessions = [sampleSession]
        return s
    }

    static var naina: PracticeScript {
        let s = PracticeScript(id: nainaID)
        s.title = "Naina"
        s.languageRaw = ScriptLanguage.hindi.rawValue
        s.rawText = """
        NAINA
        Tum samajhte kyun nahi ki agar main ek minute aur ruki to...

        BUNNY
        to kya Naina?

        NAINA
        To mujhe tumse pyaar hojaayega, firse. Aur tumhe nahi hoga, firse. Isliye bunny behtar yahi hoga ki hum ek dusre se jitnaa dur reh sake utnaa dur rahein.
        """
        s.cueLines = [
            CueLine(
                orderIndex: 0,
                speaker: "BUNNY",
                cueText: "to kya Naina?",
                precedingActorLine: "Tum samajhte kyun nahi ki agar main ek minute aur ruki to..."
            )
        ]
        return s
    }


    // MARK: - Sample AppState (for previews)

    @MainActor
    static var sampleAppState: AppState {
        let previewDefaults = UserDefaults(suiteName: "com.onetake.preview") ?? .standard
        let state = AppState(
            settings: AppSettings(defaults: previewDefaults),
            defaults: previewDefaults
        )
        state.isDemoMode = true
        state.currentUser = sampleUser
        state.auditions = sampleAuditions
        state.practiceScripts = sampleScripts
        return state
    }

    // MARK: - Preview ModelContainer

    @MainActor
    static var previewContainer: ModelContainer {
        do {
            let schema = Schema([
                UserProfile.self,
                Audition.self,
                PracticeScript.self
            ])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: schema, configurations: [config])

            let context = container.mainContext
            context.insert(sampleUser)
            for audition in sampleAuditions {
                context.insert(audition)
            }
            for script in sampleScripts {
                context.insert(script)
            }

            return container
        } catch {
            fatalError("Failed to create preview container: \(error)")
        }
    }
}
