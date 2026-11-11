import XCTest
@testable import NotebookCore

/// Topic, key sentence and material stay with their lesson: found by the
/// identity the state's invariant uses (`target.key`), in a Lernfeld block
/// under any of its lessons, and written by replacing – never a second
/// topic with the same key. Fictitious data only.
final class CalendarLessonTopicTests: XCTestCase {
    private func day(_ text: String) -> CivilDate { CivilDate(text)! }
    private func lesson(_ period: String, start: String = "2026-11-12T08:00") -> CalendarNoteTarget {
        .lesson(CalendarLessonAnchor(source: "s", periodID: period, lessonID: "9", originalDate: day("2026-11-12"), originalStart: start))
    }
    private let written = Date(timeIntervalSince1970: 1_793_000_000)

    func testTopicSurvivesAChangedStartAndCanBeWrittenAgain() throws {
        var state = CalendarState()
        let stored = CalendarLessonTopic(target: lesson("4711"), topic: "Bilanz", summary: "Aktiva = Passiva", modifiedAt: written)
        state.lessonTopics = [stored]
        // The same period delivered with another start.
        let now = lesson("4711", start: "2026-11-12T09:45")
        XCTAssertNotEqual(stored.target, now)
        XCTAssertEqual(CalendarLessonTopics.topic(in: state.lessonTopics, target: now), stored)

        CalendarLessonTopics.update(&state.lessonTopics, target: now) { $0.topic = "Bilanz und GuV" }
        XCTAssertEqual(state.lessonTopics.count, 1)
        let topic = try XCTUnwrap(state.lessonTopics.first)
        XCTAssertEqual(topic.id, stored.id)
        XCTAssertEqual(topic.topic, "Bilanz und GuV")
        XCTAssertEqual(topic.summary, "Aktiva = Passiva")
        XCTAssertEqual(topic.target, now)
        XCTAssertNoThrow(try state.validate())
    }

    func testBlockTopicStaysWhenItsFirstLessonIsCancelledAndComesBack() throws {
        var state = CalendarState()
        let first = lesson("100"), second = lesson("101", start: "2026-11-12T08:45"), other = lesson("200", start: "2026-11-12T11:00")
        let block = [first, second]
        let stored = CalendarLessonTopic(target: first, topic: "Die Lieferung", modifiedAt: written)
        let unrelated = CalendarLessonTopic(target: other, topic: "Deutsch", modifiedAt: written)
        state.lessonTopics = [stored, unrelated]
        // First lesson cancelled: the block's first lesson is now the second.
        XCTAssertEqual(CalendarLessonTopics.topic(in: state.lessonTopics, target: second, block: block), stored)
        XCTAssertNil(CalendarLessonTopics.topic(in: state.lessonTopics, target: second), "without its block the other period has no topic")

        CalendarLessonTopics.update(&state.lessonTopics, target: second, block: block) { $0.summary = "Verfügungsmacht" }
        XCTAssertEqual(state.lessonTopics.count, 2)
        let moved = try XCTUnwrap(state.lessonTopics.first { $0.id == stored.id })
        XCTAssertEqual(moved.target, second)
        XCTAssertEqual(moved.topic, "Die Lieferung")
        XCTAssertEqual(moved.summary, "Verfügungsmacht")
        XCTAssertEqual(state.lessonTopics.first { $0.id == unrelated.id }, unrelated)
        XCTAssertNoThrow(try state.validate())
        // Cancellation withdrawn: the first lesson leads again and still shows the topic.
        XCTAssertEqual(CalendarLessonTopics.topic(in: state.lessonTopics, target: first, block: block)?.id, stored.id)
    }

    func testOwnTopicWinsOverTheBlocksAndOtherTopicsOfTheBlockStay() {
        let first = lesson("100"), second = lesson("101", start: "2026-11-12T08:45")
        // Written separately before the two lessons became one block.
        let a = CalendarLessonTopic(target: first, topic: "A", modifiedAt: written)
        let b = CalendarLessonTopic(target: second, topic: "B", modifiedAt: written)
        var topics = [a, b]
        XCTAssertEqual(CalendarLessonTopics.topic(in: topics, target: second, block: [first, second]), b)
        CalendarLessonTopics.update(&topics, target: second, block: [first, second]) { $0.topic = "" }
        XCTAssertEqual(topics, [a], "only the topic that was shown is removed")
    }

    func testNormalCaseCreatesReplacesAndRemoves() throws {
        var state = CalendarState()
        let target = lesson("4711"), event = CalendarNoteTarget.local(event: UUID(), date: day("2026-11-12"))
        XCTAssertNil(CalendarLessonTopics.topic(in: state.lessonTopics, target: target))
        CalendarLessonTopics.update(&state.lessonTopics, target: target) { $0.topic = "Bilanz"; $0.modifiedAt = self.written }
        CalendarLessonTopics.update(&state.lessonTopics, target: event) { $0.topic = "Elternabend"; $0.modifiedAt = self.written }
        XCTAssertEqual(state.lessonTopics.map(\.topic), ["Bilanz", "Elternabend"])
        XCTAssertNoThrow(try state.validate())
        let id = try XCTUnwrap(CalendarLessonTopics.topic(in: state.lessonTopics, target: target)).id
        CalendarLessonTopics.update(&state.lessonTopics, target: target) { $0.topic = "GuV" }
        XCTAssertEqual(CalendarLessonTopics.topic(in: state.lessonTopics, target: target)?.topic, "GuV")
        XCTAssertEqual(CalendarLessonTopics.topic(in: state.lessonTopics, target: target)?.id, id)
        XCTAssertEqual(state.lessonTopics.count, 2)
        // Nothing left of it: removed; an empty new one is never stored.
        CalendarLessonTopics.update(&state.lessonTopics, target: target) { $0.topic = "" }
        CalendarLessonTopics.update(&state.lessonTopics, target: lesson("9999")) { _ in }
        XCTAssertEqual(state.lessonTopics.map(\.topic), ["Elternabend"])
        // Another occurrence of the same event is another target.
        XCTAssertNil(CalendarLessonTopics.topic(in: state.lessonTopics, target: .local(event: UUID(), date: day("2026-11-12"))))
    }

    func testAStateThatAlreadyHasTwoTopicsOfOneKeyIsRepairedByWriting() {
        // What the old lookup left behind when the write failed only later (in memory).
        var state = CalendarState()
        state.lessonTopics = [CalendarLessonTopic(target: lesson("4711"), topic: "alt", modifiedAt: written),
                              CalendarLessonTopic(target: lesson("4711", start: "2026-11-12T09:45"), topic: "neu", modifiedAt: written)]
        XCTAssertThrowsError(try state.validate())
        CalendarLessonTopics.update(&state.lessonTopics, target: lesson("4711", start: "2026-11-12T09:45")) { $0.topic = "Bilanz" }
        XCTAssertEqual(state.lessonTopics.map(\.topic), ["Bilanz"])
        XCTAssertNoThrow(try state.validate())
    }

    func testTopicsFollowADeliberateSourceMove() {
        let eventID = UUID(), start = Date(timeIntervalSince1970: 1_795_000_000)
        var topics = [CalendarLessonTopic(target: .local(event: eventID, date: nil), topic: "Einzeltermin", modifiedAt: written),
                      CalendarLessonTopic(target: .local(event: eventID, date: day("2026-11-20")), topic: "Serie", modifiedAt: written)]
        let anchor = CalendarSystemAnchor(externalID: "EXT-7", itemID: "i7", calendarID: "cal-a", occurrence: nil)
        CalendarSourceMove.retargetLocal(topics: &topics, event: eventID, to: anchor)
        XCTAssertEqual(topics.map(\.target), [.system(anchor), .local(event: eventID, date: day("2026-11-20"))])
        let back = UUID()
        CalendarSourceMove.retargetSystem(topics: &topics, from: anchor, to: back)
        XCTAssertEqual(topics.first?.target, .local(event: back, date: nil))

        // A new identity keeps the occurrence; of two topics that then share a key the newer stays.
        let new = CalendarSystemAnchor(externalID: "EXT-8", itemID: "i8", calendarID: "cal-b", occurrence: nil)
        var moved = [CalendarLessonTopic(target: .system(CalendarSystemAnchor(externalID: "EXT-7", itemID: "i7", calendarID: "cal-a", occurrence: start)),
                                         topic: "älter", modifiedAt: written),
                     CalendarLessonTopic(target: .system(CalendarSystemAnchor(externalID: "EXT-8", itemID: "i8", calendarID: "cal-b", occurrence: start)),
                                         topic: "neuer", modifiedAt: written.addingTimeInterval(60))]
        CalendarSourceMove.retarget(topics: &moved, from: anchor, to: new)
        XCTAssertEqual(moved.map(\.topic), ["neuer"])
        var state = CalendarState()
        state.lessonTopics = moved
        XCTAssertNoThrow(try state.validate())
    }
}
