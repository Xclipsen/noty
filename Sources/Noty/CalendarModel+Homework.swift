import Foundation
import NotebookCore

// Homework of WebUntis (Stufe C) with the local „erledigt“ marks.
// Moved out of CalendarModel+System.swift unchanged.

extension CalendarModel {
    // MARK: Homework (WebUntis)

    /// Homework of the offline timetable with the local „erledigt“ marks,
    /// sorted by due date. Empty without WebUntis.
    var homework: [CalendarHomeworkItem] {
        guard let snapshot, snapshot.connection == state.connection?.id else { return [] }
        return CalendarHomeworkItem.items(snapshot: snapshot, marks: state.homeworkDone, source: state.connection?.source)
    }

    /// Open (not done) homework.
    var openHomework: [CalendarHomeworkItem] { homework.filter { !$0.done } }

    func homework(dueOn day: Date) -> [CalendarHomeworkItem] {
        let date = CivilDate(day, calendar: calendar)
        return homework.filter { $0.homework.due == date }
    }

    /// Homework given in or due in this lesson.
    func homework(for entry: CalendarEntry) -> [CalendarHomeworkItem] {
        guard let lesson = snapshot?.lessons.first(where: { $0.id == entry.id }) else { return [] }
        return homework.filter { $0.homework.periodID == lesson.key.sourceID || $0.dueLessonID == lesson.key.sourceID }
    }

    /// „Erledigt“ is stored locally (calendar package, backup); WebUntis is not told.
    func setHomeworkDone(_ id: String, done: Bool) async {
        guard let source = state.connection?.source else { return }
        await commit { state in
            state.homeworkDone.removeAll { $0.source == source && $0.homeworkID == id }
            if done { state.homeworkDone.append(CalendarHomeworkMark(source: source, homeworkID: id)) }
            if state.homeworkDone.count > CalendarState.maximumHomeworkMarks {
                state.homeworkDone.sort { $0.doneAt < $1.doneAt }
                state.homeworkDone.removeFirst(state.homeworkDone.count - CalendarState.maximumHomeworkMarks)
            }
        }
    }

    func buildHomeworkIndex() {
        homeworkByPeriod = [:]; homeworkByDue = [:]
        guard let snapshot, snapshot.connection == state.connection?.id else { return }
        for item in snapshot.homework {
            homeworkByPeriod[item.periodID, default: []].append(item)
            if let course = item.lessonID { homeworkByDue[course + "|" + item.due.description, default: []].append(item) }
        }
    }

    /// Lines for a lesson's details: homework due in it and given in it.
    func homeworkNotes(for lesson: CalendarLesson) -> [String] {
        let due = lesson.key.seriesID.flatMap { homeworkByDue[$0 + "|" + lesson.date.description] } ?? []
        let given = (homeworkByPeriod[lesson.key.sourceID] ?? []).filter { item in !due.contains { $0.id == item.id } }
        guard !due.isEmpty || !given.isEmpty else { return [] }
        let done = Set(state.homeworkDone.filter { $0.source == state.connection?.source }.map(\.homeworkID))
        func line(_ item: CalendarHomework) -> String {
            (item.text.isEmpty ? "ohne Text" : String(item.text.prefix(200))) + (done.contains(item.id) ? " (erledigt)" : "")
        }
        return due.map { "Hausaufgabe fällig: " + line($0) }
            + given.map { "Hausaufgabe bis " + String(format: "%02d.%02d.", $0.due.day, $0.due.month) + ": " + line($0) }
    }
}
