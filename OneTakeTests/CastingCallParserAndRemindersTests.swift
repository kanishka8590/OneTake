import Compression
import CoreML
import NaturalLanguage
import PDFKit
import UIKit
import XCTest
@testable import OneTake

final class CastingCallParserAndRemindersTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDown() {
        for dir in tempDirectories {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneTakeTask5Tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirectories.append(dir)
        return dir
    }

    // MARK: - ZipArchive & DOCX Tests

    func testZipArchiveWriteExtractAndReadDocxDocumentXML() async throws {
        let dir = try makeTempDir()
        let zipURL = dir.appendingPathComponent("sample.docx")
        let extractDir = dir.appendingPathComponent("extracted", isDirectory: true)

        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>PROJECT: Neon Horizon</w:t></w:r></w:p>
            <w:p><w:r><w:t>ROLE: DETECTIVE COLE</w:t></w:r></w:p>
            <w:p><w:r><w:t>Submit to: casting@neonfilm.com</w:t></w:r></w:p>
            <w:p><w:r><w:t>DETECTIVE COLE: Did you lock the back door?</w:t></w:r></w:p>
            <w:p><w:r><w:t>LADY MACBETH: Out, damned spot!</w:t></w:r></w:p>
          </w:body>
        </w:document>
        """
        let xmlData = Data(documentXML.utf8)
        let contentTypesData = Data("<Types></Types>".utf8)

        try ZipArchive.write([
            (name: "[Content_Types].xml", data: contentTypesData),
            (name: "word/document.xml", data: xmlData)
        ], to: zipURL)

        // Extract to directory round-trip
        try ZipArchive.extract(from: zipURL, to: extractDir)
        let extractedXML = try Data(contentsOf: extractDir.appendingPathComponent("word/document.xml"))
        XCTAssertEqual(extractedXML, xmlData)

        // Read single entry in-memory + parseDocx
        let archiveData = try Data(contentsOf: zipURL)
        let inMemoryXML = try ZipArchive.readEntry(named: "word/document.xml", from: archiveData)
        XCTAssertEqual(inMemoryXML, xmlData)

        let parsed = try await CastingCallParserService.shared.parseDocx(data: archiveData)
        XCTAssertEqual(parsed.projectName, "Neon Horizon")
        XCTAssertEqual(parsed.recipientEmail, "casting@neonfilm.com")
        XCTAssertTrue(parsed.hasDetectedScript)
        XCTAssertFalse(parsed.cueLines.isEmpty)
    }

    func testZipArchiveDeflateAndBit3DataDescriptorDocxParsing() async throws {
        let dir = try makeTempDir()
        let docxURL = dir.appendingPathComponent("deflate_dd.docx")

        let xmlText = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>PROJECT: Midnight Express</w:t></w:r></w:p>
            <w:p><w:r><w:t>5s slate</w:t></w:r></w:p>
            <w:p><w:r><w:t>Send to: auditions@midnight.org</w:t></w:r></w:p>
          </w:body>
        </w:document>
        """
        let rawPayload = Data(xmlText.utf8)
        let archiveData = try makeDeflateZipWithBit3DataDescriptor(
            entryName: "word/document.xml",
            payload: rawPayload
        )
        try archiveData.write(to: docxURL)

        // Verify extract() handles DEFLATE + bit-3 Data Descriptor
        let extractDir = dir.appendingPathComponent("out", isDirectory: true)
        try ZipArchive.extract(from: docxURL, to: extractDir)
        let extracted = try Data(contentsOf: extractDir.appendingPathComponent("word/document.xml"))
        XCTAssertEqual(extracted, rawPayload)

        // Verify CastingCallParserService.parseDocx reads DEFLATE + bit-3 Data Descriptor
        let parsed = try await CastingCallParserService.shared.parseDocx(data: archiveData)
        XCTAssertEqual(parsed.projectName, "Midnight Express")
        XCTAssertEqual(parsed.maxSlateSeconds, 5.0)
        XCTAssertEqual(parsed.recipientEmail, "auditions@midnight.org")
    }

    // MARK: - OCR Column Reconstruction & Scanned PDF Tests

    func testOCRColumnReconstructionOrdersTwoColumnsAndNeverReturnsEmpty() {
        let boxes: [OCRLayoutReconstructor.TextBoundingBox] = [
            OCRLayoutReconstructor.TextBoundingBox(
                text: "CASTING CALL",
                rect: CGRect(x: 0.25, y: 0.88, width: 0.50, height: 0.05)
            ),
            OCRLayoutReconstructor.TextBoundingBox(
                text: "PROJECT: Glass Harbor",
                rect: CGRect(x: 0.05, y: 0.72, width: 0.35, height: 0.04)
            ),
            OCRLayoutReconstructor.TextBoundingBox(
                text: "ROLE: Elena",
                rect: CGRect(x: 0.05, y: 0.62, width: 0.30, height: 0.04)
            ),
            OCRLayoutReconstructor.TextBoundingBox(
                text: "Deadline: Friday",
                rect: CGRect(x: 0.58, y: 0.72, width: 0.34, height: 0.04)
            ),
            OCRLayoutReconstructor.TextBoundingBox(
                text: "Submit to: cast@glass.io",
                rect: CGRect(x: 0.58, y: 0.62, width: 0.36, height: 0.04)
            )
        ]

        let reconstructed = CastingCallParserService.reconstructColumns(from: boxes)
        XCTAssertFalse(reconstructed.isEmpty)
        XCTAssertTrue(reconstructed.contains("CASTING CALL"))
        XCTAssertTrue(reconstructed.contains("PROJECT: Glass Harbor"))
        XCTAssertTrue(reconstructed.contains("Submit to: cast@glass.io"))
    }

    func testParseImageRunsVisionOCROffMainActorAndExtractsText() async throws {
        let image = renderTestDocumentImage(lines: [
            "PROJECT: Echoes of Dawn",
            "ROLE: MAYA",
            "Submit to: casting@echoes.com",
            "5s slate",
            "90s clip"
        ])

        let parsed = try await CastingCallParserService.shared.parseImage(image)
        XCTAssertFalse(parsed.rawExtractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(parsed.rawExtractedText.localizedCaseInsensitiveContains("Echoes"))
        XCTAssertEqual(parsed.recipientEmail.lowercased(), "casting@echoes.com")
    }

    func testScannedPDFWithNonZeroMediaBoxOriginRunsVisionOCR() async throws {
        let image = renderTestDocumentImage(lines: [
            "PROJECT: Scanned Sides",
            "Submit to: scan@studio.com"
        ])
        let pdfData = makeImageOnlyPDF(image: image, origin: CGPoint(x: 36, y: 48))

        let extracted = try await CastingCallParserService.shared.extractRawText(fromPDF: pdfData)
        XCTAssertFalse(extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(extracted.localizedCaseInsensitiveContains("Scanned"))
    }

    // MARK: - Regex & Priority Rules Tests

    func testRegexEdgeCasesSlateClipWordBoundariesAndEmailPriority() async {
        let notice = """
        Agency Info: agent@talentagency.com
        Audition Location: Times Square, New York
        We are casting a gripping screenplay about journalists in NYC.
        Submit to: casting@premierestudio.com
        Requirements:
        - 5s slate
        - 90 seconds clip
        - Headshot: 4:5 portrait (do not crop in Times Square)
        """

        let parsed = await CastingCallParserService.shared.parseText(notice)

        XCTAssertEqual(parsed.maxSlateSeconds, 5.0)
        XCTAssertEqual(parsed.maxClipSeconds, 90.0)
        XCTAssertEqual(parsed.productionType, .featureFilm, "\"screenplay\" must not trigger .theater")
        XCTAssertEqual(parsed.requiredHeadshotRatio, .ratio4x5, "\"Times Square\" must not trigger .ratio1x1")
        XCTAssertEqual(parsed.recipientEmail, "casting@premierestudio.com")
    }

    func testSlateColonAndMinuteClipAndSquareHeadshotRegexes() async {
        let notice = """
        PROJECT: Stage Revival
        Looking for leads in a new play.
        Slate: 30s
        2 min clip
        Headshot: square
        Send to: theater@broadwaystage.org
        """

        let parsed = await CastingCallParserService.shared.parseText(notice)

        XCTAssertEqual(parsed.maxSlateSeconds, 30.0)
        XCTAssertEqual(parsed.maxClipSeconds, 120.0)
        XCTAssertEqual(parsed.productionType, .theater)
        XCTAssertEqual(parsed.requiredHeadshotRatio, .ratio1x1)
        XCTAssertEqual(parsed.recipientEmail, "theater@broadwaystage.org")
    }

    // MARK: - Dialogue, Screenplay & CoreML Tests

    func testParseDialogueHandlesMultiLineColonAndMultiWordNamesAndCoreML() async {
        let sides = """
        PROJECT: Macbeth Modern
        INT. CORRIDOR - NIGHT

        LADY MACBETH:
        Out, damned spot! Out, I say!

        DOCTOR:
        How came she by that light?

        LADY MACBETH:
        (whispering)
        Here's the smell of the blood still.
        """

        let parsed = await CastingCallParserService.shared.parseText(sides)
        XCTAssertTrue(parsed.hasDetectedScript)
        XCTAssertEqual(parsed.detectedMainRole, "LADY MACBETH")
        XCTAssertEqual(parsed.detectedCueRole, "DOCTOR")
        XCTAssertEqual(parsed.cueLines.count, 1)
        XCTAssertEqual(parsed.cueLines.first?.speaker, "DOCTOR")
        XCTAssertEqual(parsed.cueLines.first?.cueText, "How came she by that light?")
        XCTAssertEqual(parsed.cueLines.first?.isAutoDetected, true)

        // Verify AuditionModeAndCuesView.buildDisplayLines handles the formatted multi-line output
        let script = parsed.detectedScriptText ?? ""
        let display = AuditionModeAndCuesView.buildDisplayLines(
            from: script,
            roleName: "LADY MACBETH",
            existingCueLines: parsed.cueLines
        )
        XCTAssertTrue(display.isDialogueDetected)
        XCTAssertEqual(display.lines.count, 3)
        XCTAssertEqual(display.lines[1].speaker, "DOCTOR")
        XCTAssertEqual(display.lines[1].text, "How came she by that light?")
        XCTAssertTrue(display.lines[1].isAutoDetectedCue)
        XCTAssertTrue(display.lines[1].isCurrentlyActiveCue)
    }

    func testParseDialogueHandlesColonlessScreenplayFormat() async {
        let screenplay = """
        INT. DINER - NIGHT

        DETECTIVE COLE
        (tired)
        Where were you at midnight?

        WAITRESS
        I was closing up the register, same as every Tuesday.

        DETECTIVE COLE
        Did anyone else have a key?
        """

        let parsed = await CastingCallParserService.shared.parseText(screenplay)
        XCTAssertTrue(parsed.hasDetectedScript)
        XCTAssertEqual(parsed.detectedMainRole, "DETECTIVE COLE")
        XCTAssertEqual(parsed.cueLines.count, 1)
        XCTAssertEqual(parsed.cueLines.first?.speaker, "WAITRESS")
        XCTAssertEqual(parsed.cueLines.first?.cueText, "I was closing up the register, same as every Tuesday.")

        let display = AuditionModeAndCuesView.buildDisplayLines(
            from: screenplay,
            roleName: "DETECTIVE COLE",
            existingCueLines: []
        )
        XCTAssertTrue(display.isDialogueDetected)
        let activeCues = display.lines.filter(\.isCurrentlyActiveCue)
        XCTAssertEqual(activeCues.count, 1)
        XCTAssertEqual(activeCues.first?.speaker, "WAITRESS")
        XCTAssertTrue(activeCues.first?.isAutoDetectedCue == true)
    }

    // MARK: - AuditionReminderService Tests

    func testAuditionReminderServicePlannedRemindersComputation() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let activeFuture = Audition(
            projectName: "Feature Lead",
            roleName: "Maya",
            deadline: now.addingTimeInterval(3 * 3600),
            reminderOffsetMinutes: 60,
            statusRaw: AuditionStatus.active.rawValue
        )

        let sentFuture = Audition(
            projectName: "Already Sent",
            roleName: "Alex",
            deadline: now.addingTimeInterval(5 * 3600),
            reminderOffsetMinutes: 60,
            statusRaw: AuditionStatus.sent.rawValue
        )

        let pastDeadline = Audition(
            projectName: "Expired Call",
            roleName: "Sam",
            deadline: now.addingTimeInterval(-3600),
            reminderOffsetMinutes: 60,
            statusRaw: AuditionStatus.active.rawValue
        )

        let reminderWindowPassed = Audition(
            projectName: "Due in 30m",
            roleName: "Lee",
            deadline: now.addingTimeInterval(1800),
            reminderOffsetMinutes: 60,
            statusRaw: AuditionStatus.active.rawValue
        )

        let planned = AuditionReminderService.plannedReminders(
            for: [activeFuture, sentFuture, pastDeadline, reminderWindowPassed],
            enabled: true,
            now: now
        )

        XCTAssertEqual(planned.count, 1)
        XCTAssertEqual(planned.first?.auditionID, activeFuture.id)
        XCTAssertEqual(planned.first?.date, now.addingTimeInterval(2 * 3600))
        XCTAssertTrue(planned.first?.title.contains("Feature Lead") == true)

        let disabled = AuditionReminderService.plannedReminders(
            for: [activeFuture],
            enabled: false,
            now: now
        )
        XCTAssertTrue(disabled.isEmpty)
    }

    func testAuditionReminderServiceTogglesForAuditionsSubmissionsAndPractice() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 7, minute: 0)))
        let deadline = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 17, minute: 0)))

        let auditionWithSides = Audition(
            projectName: "Horizon Pilot",
            roleName: "Maya",
            deadline: deadline,
            reminderOffsetMinutes: 60,
            statusRaw: AuditionStatus.active.rawValue,
            scriptText: "MAYA: We leave at dawn."
        )

        // 1) Auditions only: schedules custom 4:00 PM deadline + 9:00 AM morning-of; omits submission & practice
        let auditionsOnly = AuditionReminderService.plannedReminders(
            for: [auditionWithSides],
            notifyAuditions: true,
            notifySubmissions: false,
            notifyPractice: false,
            practiceScripts: [],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(auditionsOnly.count, 2)
        XCTAssertTrue(auditionsOnly.contains { $0.id == "\(AuditionReminderService.identifierPrefix)deadline.\(auditionWithSides.id.uuidString)" })
        XCTAssertTrue(auditionsOnly.contains { $0.id == "\(AuditionReminderService.identifierPrefix)morning.\(auditionWithSides.id.uuidString)" })
        XCTAssertFalse(auditionsOnly.contains { $0.id.hasPrefix(AuditionReminderService.submissionIdentifierPrefix) })
        XCTAssertFalse(auditionsOnly.contains { $0.id == AuditionReminderService.practiceIdentifier })

        // 2) Submissions enabled: adds 2-hour submission urgency reminder at 3:00 PM
        let withSubmissions = AuditionReminderService.plannedReminders(
            for: [auditionWithSides],
            notifyAuditions: true,
            notifySubmissions: true,
            notifyPractice: false,
            practiceScripts: [],
            now: now,
            calendar: calendar
        )
        let submissionReminders = withSubmissions.filter {
            $0.id.hasPrefix(AuditionReminderService.submissionIdentifierPrefix)
        }
        XCTAssertEqual(submissionReminders.count, 1)
        XCTAssertEqual(submissionReminders.first?.date, deadline.addingTimeInterval(-2 * 3600))
        XCTAssertTrue(submissionReminders.first?.title.contains("2 hours left to submit") == true)

        // 3) Submissions only (auditions off)
        let submissionsOnly = AuditionReminderService.plannedReminders(
            for: [auditionWithSides],
            notifyAuditions: false,
            notifySubmissions: true,
            notifyPractice: false,
            practiceScripts: [],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(submissionsOnly.count, 1)
        XCTAssertTrue(submissionsOnly.first?.id.hasPrefix(AuditionReminderService.submissionIdentifierPrefix) == true)

        // 4) Practice enabled with active sides -> daily 6:00 PM repeating reminder
        let withPractice = AuditionReminderService.plannedReminders(
            for: [auditionWithSides],
            notifyAuditions: false,
            notifySubmissions: false,
            notifyPractice: true,
            practiceScripts: [],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(withPractice.count, 1)
        XCTAssertEqual(withPractice.first?.id, AuditionReminderService.practiceIdentifier)
        XCTAssertEqual(withPractice.first?.title, "Run your lines")
        XCTAssertEqual(withPractice.first?.repeatsDaily, true)
        XCTAssertEqual(calendar.component(.hour, from: try XCTUnwrap(withPractice.first?.date)), 18)

        // 5) Practice enabled with PracticeScript only (no active auditions)
        let practiceScript = PracticeScript(title: "Hamlet Act III", rawText: "To be, or not to be.")
        let scriptPractice = AuditionReminderService.plannedReminders(
            for: [],
            notifyAuditions: false,
            notifySubmissions: false,
            notifyPractice: true,
            practiceScripts: [practiceScript],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(scriptPractice.count, 1)
        XCTAssertEqual(scriptPractice.first?.id, AuditionReminderService.practiceIdentifier)
        XCTAssertTrue(scriptPractice.first?.body.contains("Hamlet Act III") == true)

        // 6) Practice enabled with no active sides and no practice scripts -> empty
        let noSidesAudition = Audition(
            projectName: "Silent Audition",
            roleName: "Extra",
            deadline: deadline,
            statusRaw: AuditionStatus.active.rawValue,
            scriptText: nil
        )
        let noPractice = AuditionReminderService.plannedReminders(
            for: [noSidesAudition],
            notifyAuditions: false,
            notifySubmissions: false,
            notifyPractice: true,
            practiceScripts: [],
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(noPractice.isEmpty)
    }

    // MARK: - Test Helpers

    private func renderTestDocumentImage(lines: [String]) -> UIImage {
        let size = CGSize(width: 900, height: 600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 32, weight: .semibold),
                .foregroundColor: UIColor.black
            ]
            for (index, line) in lines.enumerated() {
                let rect = CGRect(x: 48, y: 48 + CGFloat(index) * 64, width: size.width - 96, height: 48)
                (line as NSString).draw(in: rect, withAttributes: attrs)
            }
        }
    }

    private func makeImageOnlyPDF(image: UIImage, origin: CGPoint) -> Data {
        let bounds = CGRect(origin: origin, size: image.size)
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, bounds, nil)
        UIGraphicsBeginPDFPageWithInfo(bounds, nil)
        image.draw(in: bounds)
        UIGraphicsEndPDFContext()
        return data as Data
    }

    private func makeDeflateZipWithBit3DataDescriptor(entryName: String, payload: Data) throws -> Data {
        let compressedCapacity = max(payload.count + 256, 512)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: compressedCapacity)
        defer { dst.deallocate() }

        let compressedSize = payload.withUnsafeBytes { rawSrc -> Int in
            guard let srcPtr = rawSrc.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                dst,
                compressedCapacity,
                srcPtr,
                payload.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        XCTAssertGreaterThan(compressedSize, 0)
        let compressedData = Data(bytes: dst, count: compressedSize)
        let checksum = ZipArchive.crc32(payload)
        let nameData = Data(entryName.utf8)

        var archive = Data()
        let localHeaderOffset = UInt32(archive.count)

        // Local file header with bit-3 data descriptor flag (0x0008) & zeroed sizes/CRC
        appendUInt32(0x04034b50, to: &archive)
        appendUInt16(20, to: &archive)
        appendUInt16(0x0808, to: &archive) // UTF-8 (0x0800) + bit 3 data descriptor (0x0008)
        appendUInt16(8, to: &archive)      // method 8 = DEFLATE
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt32(0, to: &archive)      // CRC deferred to data descriptor
        appendUInt32(0, to: &archive)      // compressed size deferred
        appendUInt32(0, to: &archive)      // uncompressed size deferred
        appendUInt16(UInt16(nameData.count), to: &archive)
        appendUInt16(0, to: &archive)
        archive.append(nameData)
        archive.append(compressedData)

        // Data descriptor
        appendUInt32(0x08074b50, to: &archive)
        appendUInt32(checksum, to: &archive)
        appendUInt32(UInt32(compressedData.count), to: &archive)
        appendUInt32(UInt32(payload.count), to: &archive)

        // Central directory header
        let centralStart = UInt32(archive.count)
        appendUInt32(0x02014b50, to: &archive)
        appendUInt16(20, to: &archive)
        appendUInt16(20, to: &archive)
        appendUInt16(0x0808, to: &archive)
        appendUInt16(8, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt32(checksum, to: &archive)
        appendUInt32(UInt32(compressedData.count), to: &archive)
        appendUInt32(UInt32(payload.count), to: &archive)
        appendUInt16(UInt16(nameData.count), to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt32(0, to: &archive)
        appendUInt32(localHeaderOffset, to: &archive)
        archive.append(nameData)

        let centralSize = UInt32(archive.count) - centralStart

        // End of central directory
        appendUInt32(0x06054b50, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(1, to: &archive)
        appendUInt16(1, to: &archive)
        appendUInt32(centralSize, to: &archive)
        appendUInt32(centralStart, to: &archive)
        appendUInt16(0, to: &archive)

        return archive
    }

    func testAuditionListFilterBehavior() {
        let activeAudition = Audition(projectName: "Active Project", roleName: "Hero")
        activeAudition.status = .active
        let sentAudition = Audition(projectName: "Sent Project", roleName: "Detective")
        sentAudition.status = .sent
        let allAuditions = [activeAudition, sentAudition]

        let filteredActive = allAuditions.filter { $0.status == .active }
        XCTAssertEqual(filteredActive.count, 1)
        XCTAssertEqual(filteredActive.first?.projectName, "Active Project")

        let filteredSent = allAuditions.filter { $0.status == .sent }
        XCTAssertEqual(filteredSent.count, 1)
        XCTAssertEqual(filteredSent.first?.projectName, "Sent Project")

        XCTAssertEqual(AuditionListFilter.allCases.map(\.rawValue), ["Active", "Sent", "All"])
    }

    func testMissingDeadlineLeavesHasDetectedDeadlineFalse() async {
        let notice = """
        CASTING CALL - THE QUIET HARBOR
        Role: Supporting Lead
        Send self-tape to casting@quietharbor.com
        """
        let parsed = await CastingCallParserService.shared.parseText(notice)
        XCTAssertFalse(parsed.hasDetectedDeadline)

        let noticeWithDeadline = """
        CASTING CALL - THE QUIET HARBOR
        Role: Supporting Lead
        Deadline: December 15, 2026 at 5:00 PM
        Send self-tape to casting@quietharbor.com
        """
        let parsedWithDeadline = await CastingCallParserService.shared.parseText(noticeWithDeadline)
        XCTAssertTrue(parsedWithDeadline.hasDetectedDeadline)
    }

    func testParseUserDeadlineInputHandlesTypedDatesAndRejectsInvalidText() {
        let parser = CastingCallParserService.shared

        let slashDate = parser.parseUserDeadlineInput("30/11/2026 17:00")
        XCTAssertNotNil(slashDate)
        if let slashDate {
            XCTAssertEqual(Calendar.current.component(.day, from: slashDate), 30)
            XCTAssertEqual(Calendar.current.component(.month, from: slashDate), 11)
            XCTAssertEqual(Calendar.current.component(.year, from: slashDate), 2026)
            XCTAssertEqual(Calendar.current.component(.hour, from: slashDate), 17)
        }

        let naturalDate = parser.parseUserDeadlineInput("Nov 30, 2026 5:00 PM")
        XCTAssertNotNil(naturalDate)
        if let naturalDate {
            XCTAssertEqual(Calendar.current.component(.day, from: naturalDate), 30)
            XCTAssertEqual(Calendar.current.component(.month, from: naturalDate), 11)
        }

        let isoDate = parser.parseUserDeadlineInput("2026-12-15")
        XCTAssertNotNil(isoDate)
        if let isoDate {
            XCTAssertEqual(Calendar.current.component(.day, from: isoDate), 15)
            XCTAssertEqual(Calendar.current.component(.month, from: isoDate), 12)
            XCTAssertEqual(Calendar.current.component(.hour, from: isoDate), 18)
        }

        XCTAssertNil(parser.parseUserDeadlineInput(""))
        XCTAssertNil(parser.parseUserDeadlineInput("12"))
        XCTAssertNil(parser.parseUserDeadlineInput("not a deadline at all"))
    }

    func testAuditionWithoutDeadlineIsNeverOverdueAndSkipsReminders() {
        let pastDate = Date().addingTimeInterval(-7200)
        let audition = Audition(
            projectName: "No Deadline Indie",
            roleName: "Maya",
            deadline: pastDate,
            hasDeadline: false
        )

        XCTAssertFalse(audition.isOverdue)

        let planned = AuditionReminderService.plannedReminders(
            for: [audition],
            notifyAuditions: true,
            notifySubmissions: true,
            notifyPractice: true
        )
        XCTAssertTrue(planned.isEmpty)
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8(value >> 8))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        appendUInt16(UInt16(value & 0xffff), to: &data)
        appendUInt16(UInt16(value >> 16), to: &data)
    }
}
