import SwiftUI
import SwiftData

enum MockData {

    // MARK: - User Profile

    static var sampleUser: UserProfile {
        let user = UserProfile()
        user.name = "Kusha Sharma"
        user.email = "kusha.sharma@gmail.com"
        user.height = "5'6\""
        user.age = 27
        user.basedIn = "Mumbai, India"
        user.representation = "Self-represented"
        user.previousWork = [
            "Campus Diaries (MX Player)",
            "Half CA (YouTube)",
            "Theatre: The Glass Menagerie"
        ]
        return user
    }

    // MARK: - Auditions

    static var sampleAuditions: [Audition] {
        [heerRanjha, theLastSummer, northbound]
    }

    static var heerRanjha: Audition {
        let a = Audition()
        a.projectName = "Heer Ranjha"
        a.productionType = ProductionType.featureFilm.rawValue
        a.roleName = "Heer"
        a.roleDescription = "A fierce young woman torn between family loyalty and forbidden love, set in rural Punjab."
        a.deadline = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
        a.reminderOffsetMinutes = 120
        a.recipientEmail = "casting@dharmaproductions.com"
        a.statusRaw = AuditionStatus.active.rawValue
        a.requirements = [
            SubmissionRequirement(title: "Self-tape: 2 scenes (max 3 min each)", isCompleted: false),
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
        You think love is that simple? You run and the world just... lets you go?
        """
        a.scriptFileName = "Heer_Ranjha_Sides.pdf"
        a.validationRules = ValidationRules(
            isFromNotice: true,
            requiredHeadshotRatio: .ratio4x5,
            maxSlateSeconds: 30.0,
            maxClipSeconds: 180.0,
            requiredPortrait: false,
            fileNamePattern: "KushaSharma_Heer",
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
        let a = Audition()
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
        You know what the worst part about leaving is? It's not the goodbye. It's knowing that everything will keep going without you.

        ANYA
        That's kind of the point, Meera. The world doesn't stop.

        MEERA
        (softly)
        I know. I just wish it would. Even for a second.
        """
        a.scriptFileName = "TheLastSummer_Ep101_Meera.pdf"
        a.validationRules = ValidationRules()
        a.cueLines = [
            CueLine(
                orderIndex: 0,
                speaker: "ANYA",
                cueText: "That's kind of the point, Meera. The world doesn't stop.",
                precedingActorLine: "You know what the worst part about leaving is? It's not the goodbye. It's knowing that everything will keep going without you."
            )
        ]
        a.createdAt = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date()
        return a
    }

    static var northbound: Audition {
        let a = Audition()
        a.projectName = "Northbound"
        a.productionType = ProductionType.shortFilm.rawValue
        a.roleName = "Zara"
        a.roleDescription = "A truck driver's daughter making a solo journey through the Himalayas."
        a.deadline = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        a.reminderOffsetMinutes = 30
        a.recipientEmail = "submissions@northboundfilm.in"
        a.statusRaw = AuditionStatus.sent.rawValue
        a.sentDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())
        a.requirements = [
            SubmissionRequirement(title: "Self-tape: 1 scene", isCompleted: true),
            SubmissionRequirement(title: "Headshot", isCompleted: true),
            SubmissionRequirement(title: "Slate video", isCompleted: true)
        ]
        a.scriptText = """
        ZARA
        The pass is closed. They told me three times at Manali. But my father's rig is stuck at Rohtang, and no one else is going up there.
        """
        a.createdAt = Calendar.current.date(byAdding: .day, value: -10, to: Date()) ?? Date()
        return a
    }

    // MARK: - Practice Scripts

    static var sampleScripts: [PracticeScript] {
        [noahAndAllie, naina, tigerTalk]
    }

    static var noahAndAllie: PracticeScript {
        let s = PracticeScript()
        s.title = "Noah & Allie"
        s.languageRaw = ScriptLanguage.english.rawValue
        s.rawText = """
        ALLIE
        Why didn't you write me? Why? It wasn't over for me. I waited for you for seven years!

        NOAH
        I wrote you 365 letters. I wrote you every day for a year.

        ALLIE
        (stunned)
        You wrote me?

        NOAH
        Yes. It wasn't over. It still isn't over.
        """
        s.cueLines = [
            CueLine(
                orderIndex: 0,
                speaker: "NOAH",
                cueText: "I wrote you 365 letters. I wrote you every day for a year.",
                precedingActorLine: "Why didn't you write me? Why? It wasn't over for me. I waited for you for seven years!"
            ),
            CueLine(
                orderIndex: 1,
                speaker: "NOAH",
                cueText: "Yes. It wasn't over. It still isn't over.",
                precedingActorLine: "You wrote me?"
            )
        ]
        s.lastPracticedAt = Calendar.current.date(byAdding: .hour, value: -3, to: Date())
        return s
    }

    static var naina: PracticeScript {
        let s = PracticeScript()
        s.title = "Naina"
        s.languageRaw = ScriptLanguage.hindi.rawValue
        s.rawText = """
        NAINA
        Main tumse pyaar karti hoon, Bunny. Bahut zyada. Par main apne aap se bhi pyaar karti hoon. Aur tumne mujhe wo karne nahi diya.

        BUNNY
        Naina, please...

        NAINA
        (firm)
        Nahi. Ab nahi. Tum jao. Jahan jaana hai jao. Main yahan hoon. Apni jagah.
        """
        s.cueLines = [
            CueLine(
                orderIndex: 0,
                speaker: "BUNNY",
                cueText: "Naina, please...",
                precedingActorLine: "Main tumse pyaar karti hoon, Bunny. Bahut zyada. Par main apne aap se bhi pyaar karti hoon."
            )
        ]
        return s
    }

    static var tigerTalk: PracticeScript {
        let s = PracticeScript()
        s.title = "Tiger Talk"
        s.languageRaw = ScriptLanguage.english.rawValue
        s.rawText = """
        PRIYA
        Did you know tigers can't purr? They can only purr when they exhale. So every breath out is... contentment.

        JAI
        That's not true at all.

        PRIYA
        (grinning)
        I know. But it sounded poetic, didn't it?
        """
        s.cueLines = [
            CueLine(
                orderIndex: 0,
                speaker: "JAI",
                cueText: "That's not true at all.",
                precedingActorLine: "Did you know tigers can't purr? They can only purr when they exhale. So every breath out is... contentment."
            )
        ]
        return s
    }

    // MARK: - Sample AppState (for previews)

    @MainActor
    static var sampleAppState: AppState {
        let state = AppState()
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
