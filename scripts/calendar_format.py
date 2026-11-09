"""Independent checks of noty calendar data (Kalender B1-B3), shared by
verify_library_backup.py (archive format 3) and verify_device_store.py
(`<Bereich>/Calendar/` package). Independent of the Swift code; explicit
checks raising ValueError (also under python -O). Never prints contents.

CalendarState formats: 1 (B1: events, settings, connection), 2 (B2: series,
note links, lesson mappings, subject colours, notes folder, source
identity), 3 (B3: reminders, lesson reminder setting, deleted events), 4
(Stufe C: system calendar settings, notes of system events, homework marks),
5 (Lernfelder: study fields, rules assigning lessons, lesson topics with
pinned material).
The connection record never contains access data: its keys are exactly the
known non-secret ones. A library archive carries format 3 (B3 builds) or the
current format 5 (archives of format 4 builds keep format 4). The offline timetable (cache format 1) may carry homework.
"""
import math
import re

from notebook_format import check, foundation_date, number, strict, uuid_string

CURRENT_FORMAT = 6
ARCHIVE_FORMATS = (3, 4, 5, 6)
STATE_KEYS = {"formatVersion", "events", "settings", "connection", "noteLinks", "lessonMappings", "deletedEvents", "homeworkDone",
              "studyFields", "studyRules", "lessonTopics", "subjectNotebooks"}
FIELD_KEYS = {"id", "number", "title", "notebookID", "package"}
RULE_KEYS = {"id", "subjectKey", "subjectName", "weekday", "startFrom", "startTo", "fieldID"}
TOPIC_KEYS = {"id", "target", "topic", "summary", "materials", "modifiedAt"}
MATERIAL_KEYS = {"package", "key", "label", "detail"}
PACKAGE = re.compile(r"[a-z0-9-]{1,64}")
MAXIMUM_FIELDS = 40
MAXIMUM_RULES = 500
MAXIMUM_TOPICS = 20_000
MAXIMUM_MATERIALS = 30
EVENT_KEYS = {"id", "title", "location", "details", "timing", "recurrence", "reminderMinutes", "createdAt", "modifiedAt"}
SETTINGS_KEYS = {"weekDays", "mode", "subjectColors", "notesFolderID", "lessonReminderMinutes", "systemCalendars"}
SYSTEM_KEYS = {"enabled", "hiddenCalendars", "defaultTarget"}
ANCHOR_KEYS = {"externalID", "itemID", "calendarID", "occurrence", "occurrenceLocal"}
LOCAL_OCCURRENCE = re.compile(r"\d{4}-\d\d-\d\d(T([01]\d|2[0-3]):[0-5]\d)?")
MARK_KEYS = {"source", "homeworkID", "doneAt"}
HOMEWORK_KEYS = {"id", "lessonID", "periodID", "periodDate", "assigned", "due", "subject", "subjectID", "text", "remark",
                 "completedInSource", "attachmentCount"}
MAXIMUM_MARKS = 20_000
CONNECTION_KEYS = {"id", "kind", "label", "timeZone", "connectedAt", "sourceIdentity"}
LINK_KEYS = {"id", "target", "documentID", "pageID", "createdAt", "hasContent", "contextTitle", "contextStart", "contextEnd"}
MAPPING_KEYS = {"id", "source", "fromPeriodID", "fromDate", "toPeriodID", "toDate", "confirmedAt"}
DELETED_KEYS = {"id", "event", "occurrence", "deletedAt"}
REMINDER_PRESETS = {0, 5, 10, 15, 30, 60, 1440}
LESSON_REMINDER_PRESETS = {5, 10, 15, 30, 60}
COLOURS = {"orange", "purple", "teal", "pink", "yellow", "brown", "cyan", "olive", "indigo", "mint", "gray"}
MODES = {"year", "month", "week", "day"}
DATE = re.compile(r"\d{4}-\d\d-\d\d")
MAXIMUM_EVENTS = 20_000
MAXIMUM_LINKS = 20_000
MAXIMUM_MAPPINGS = 20_000
MAXIMUM_DELETED = 1_000
SOURCE_FORMAT = 1


def text(value, low, high, message):
    check(isinstance(value, str) and low <= len(value) <= high, message)
    return value


def civil(value, message="Invalid calendar date"):
    check(isinstance(value, str) and DATE.fullmatch(value) is not None, message)
    year, month, day = (int(part) for part in value.split("-"))
    check(1 <= year <= 9999 and 1 <= month <= 12 and 1 <= day <= 31, message)
    return value


def keys(value, allowed, message):
    check(isinstance(value, dict) and set(value) <= allowed, message)


def timing(value):
    check(isinstance(value, dict), "Invalid event timing")
    if value.get("kind") == "allDay":
        keys(value, {"kind", "startDate", "endDate"}, "Invalid all-day timing")
        check(civil(value["endDate"]) > civil(value["startDate"]), "All-day event ends before it starts")
    else:
        check(value.get("kind") == "timed", "Unknown event timing")
        keys(value, {"kind", "start", "end", "timeZone"}, "Invalid timed event")
        foundation_date(value["start"]); foundation_date(value["end"])
        check(value["end"] > value["start"], "Event ends before it starts")
        text(value["timeZone"], 1, 100, "Invalid time zone")


def recurrence(value, version):
    check(version >= 2, "Series before calendar format 2")
    keys(value, {"frequency", "interval", "end", "exceptions", "overrides"}, "Invalid series")
    check(value["frequency"] in ("daily", "weekly", "monthly"), "Invalid series frequency")
    check(type(value.get("interval", 1)) is int and 1 <= value.get("interval", 1) <= 99, "Invalid series interval")
    end = value["end"]
    check(isinstance(end, dict) and end.get("kind") in ("never", "count", "until"), "Invalid series end")
    if end["kind"] == "count":
        check(type(end["count"]) is int and 1 <= end["count"] <= 999, "Invalid series count")
    if end["kind"] == "until":
        civil(end["date"])
    exceptions = value.get("exceptions", [])
    check(isinstance(exceptions, list) and len(exceptions) <= 2000 and len(set(exceptions)) == len(exceptions), "Invalid exceptions")
    for date in exceptions:
        civil(date)
    overrides = value.get("overrides", [])
    check(isinstance(overrides, list) and len(overrides) <= 2000, "Invalid changed occurrences")
    for item in overrides:
        keys(item, {"originalDate", "title", "location", "details", "timing"}, "Invalid changed occurrence")
        civil(item["originalDate"]); title(item["title"]); timing(item["timing"])
    check(len({item["originalDate"] for item in overrides}) == len(overrides), "Duplicate changed occurrence")
    return value


def title(value):
    check(isinstance(value, str) and 1 <= len(value) <= 200 and "\n" not in value and "\r" not in value
          and value == value.strip(), "Invalid event title")


def event(value, version):
    keys(value, EVENT_KEYS, "Unexpected event fields")
    uuid_string(value["id"])
    title(value["title"])
    check(len(value.get("location", "")) <= 500 and len(value.get("details", "")) <= 20_000, "Event text too long")
    timing(value["timing"])
    if value.get("recurrence") is not None:
        recurrence(value["recurrence"], version)
    if value.get("reminderMinutes") is not None:
        check(version >= 3 and value["reminderMinutes"] in REMINDER_PRESETS and type(value["reminderMinutes"]) is int,
              "Invalid reminder")
    foundation_date(value["createdAt"]); foundation_date(value["modifiedAt"])
    return value["id"].upper()


def settings(value, version):
    keys(value, SETTINGS_KEYS, "Unexpected calendar settings")
    check(value.get("weekDays", 5) in (5, 7) and value.get("mode", "week") in MODES, "Invalid calendar view settings")
    colours = value.get("subjectColors", {})
    check(isinstance(colours, dict) and len(colours) <= 2000 and (version >= 2 or not colours), "Invalid subject colours")
    check(all(isinstance(k, str) and 1 <= len(k) <= 300 and v in COLOURS for k, v in colours.items()), "Invalid subject colour")
    folder = value.get("notesFolderID")
    if folder is not None:
        check(version >= 2, "Notes folder before calendar format 2")
        folder = uuid_string(folder)
    minutes = value.get("lessonReminderMinutes")
    check(minutes is None or (version >= 3 and type(minutes) is int and minutes in LESSON_REMINDER_PRESETS), "Invalid lesson reminder")
    system = value.get("systemCalendars")
    if system is not None:
        check(version >= 4, "System calendars before calendar format 4")
        keys(system, SYSTEM_KEYS, "Unexpected system calendar settings")
        check(type(system["enabled"]) is bool, "Invalid system calendar switch")
        hidden = system.get("hiddenCalendars", [])
        check(isinstance(hidden, list) and len(hidden) <= 500 and len(set(hidden)) == len(hidden), "Invalid hidden calendars")
        for item in hidden:
            text(item, 1, 500, "Invalid hidden calendar")
        if system.get("defaultTarget") is not None:
            text(system["defaultTarget"], 1, 500, "Invalid default calendar")
    return folder


def connection(value, version):
    # Exactly the non-secret record: no key, password, token or server address can hide here.
    keys(value, CONNECTION_KEYS, "Unexpected connection fields (possible access data)")
    uuid_string(value["id"])
    check(value["kind"] == "webUntis", "Unknown connection kind")
    text(value["label"], 1, 200, "Invalid connection label")
    text(value["timeZone"], 1, 100, "Invalid connection time zone")
    foundation_date(value["connectedAt"])
    identity = value.get("sourceIdentity")
    check(identity is None or (version >= 2 and isinstance(identity, str) and len(identity) <= 200), "Invalid source identity")
    return value["id"].upper()


def link(value, version):
    keys(value, LINK_KEYS, "Unexpected note link fields")
    uuid_string(value["id"])
    note_target(value["target"], version)
    if value.get("pageID") is not None:
        uuid_string(value["pageID"])
    check(type(value["hasContent"]) is bool, "Invalid note content flag")
    text(value["contextTitle"], 1, 300, "Invalid note context")
    for key in ("createdAt", "contextStart", "contextEnd"):
        foundation_date(value[key])
    check(value["contextEnd"] >= value["contextStart"], "Invalid note context time")
    return uuid_string(value["documentID"])


def note_target(target, version):
    """Checks a note target and returns its identity key (like Swift `CalendarNoteTarget.key`)."""
    check(isinstance(target, dict) and target.get("kind") in ("local", "lesson", "system"), "Invalid note target")
    if target["kind"] == "system":
        check(version >= 4, "System event note before calendar format 4")
        keys(target, {"kind", "system"}, "Invalid note target")
        anchor = target["system"]
        keys(anchor, ANCHOR_KEYS, "Invalid system event anchor")
        text(anchor["itemID"], 1, 500, "Invalid system event id")
        text(anchor["calendarID"], 1, 500, "Invalid system calendar id")
        # Like Swift: an empty or blank external id counts as none.
        if anchor.get("externalID") is not None:
            text(anchor["externalID"], 0, 500, "Invalid external event id")
        check(anchor.get("occurrence") is None or anchor.get("occurrenceLocal") is None, "System anchor with two occurrences")
        if anchor.get("occurrence") is not None:
            foundation_date(anchor["occurrence"])
        if anchor.get("occurrenceLocal") is not None:
            local = anchor["occurrenceLocal"]
            check(isinstance(local, str) and LOCAL_OCCURRENCE.fullmatch(local) is not None, "Invalid local occurrence")
            civil(local[:10])
        return ("system", system_key(anchor))
    elif target["kind"] == "local":
        keys(target, {"kind", "event", "date"}, "Invalid note target")
        uuid_string(target["event"])
        if target.get("date") is not None:
            civil(target["date"])
        return ("local", target["event"].upper(), target.get("date"))
    else:
        keys(target, {"kind", "lesson"}, "Invalid note target")
        anchor = target["lesson"]
        keys(anchor, {"source", "periodID", "lessonID", "originalDate", "originalStart"}, "Invalid lesson anchor")
        text(anchor["source"], 1, 300, "Invalid lesson source")
        text(anchor["periodID"], 1, 100, "Invalid lesson period")
        check(anchor.get("lessonID") is None or (isinstance(anchor["lessonID"], str) and len(anchor["lessonID"]) <= 100), "Invalid lesson course")
        civil(anchor["originalDate"]); text(anchor["originalStart"], 0, 40, "Invalid lesson start")
        return ("lesson", anchor["source"], anchor["periodID"])


SUBJECT_KEYS = {"id", "subjectKey", "subjectName", "notebookID"}
MAXIMUM_SUBJECTS = 200


def study(state, version):
    """Lernfelder (format 5) and Fach-Hefte (format 6). Returns the notebook ids of fields and subjects."""
    fields = state.get("studyFields", [])
    rules = state.get("studyRules", [])
    topics = state.get("lessonTopics", [])
    check(isinstance(fields, list) and isinstance(rules, list) and isinstance(topics, list), "Invalid study data")
    check(version >= 5 or not (fields or rules or topics), "Study data before calendar format 5")
    check(len(fields) <= MAXIMUM_FIELDS and len(rules) <= MAXIMUM_RULES and len(topics) <= MAXIMUM_TOPICS, "Too much study data")
    field_ids, numbers, notebooks = set(), set(), []
    for item in fields:
        keys(item, FIELD_KEYS, "Unexpected study field fields")
        field_ids.add(uuid_string(item["id"]))
        check(type(item["number"]) is int and 1 <= item["number"] <= 99, "Invalid study field number")
        numbers.add(item["number"])
        title(item["title"])
        if item.get("notebookID") is not None:
            notebooks.append(uuid_string(item["notebookID"]))
        if item.get("package") is not None:
            check(isinstance(item["package"], str) and PACKAGE.fullmatch(item["package"]) is not None, "Invalid material package")
    check(len(field_ids) == len(fields) and len(numbers) == len(fields), "Duplicate study field")
    check(len(set(notebooks)) == len(notebooks), "Two study fields share a notebook")
    rule_ids = set()
    for item in rules:
        keys(item, RULE_KEYS, "Unexpected study rule fields")
        rule_ids.add(uuid_string(item["id"]))
        text(item["subjectKey"], 1, 300, "Invalid study rule subject")
        text(item["subjectName"], 1, 200, "Invalid study rule subject")
        check(item.get("weekday") is None or (type(item["weekday"]) is int and 1 <= item["weekday"] <= 7), "Invalid study rule weekday")
        start, end = item.get("startFrom"), item.get("startTo")
        check((start is None and end is None) or (type(start) is int and type(end) is int and 0 <= start < end <= 1440),
              "Invalid study rule time")
        check(uuid_string(item["fieldID"]) in field_ids, "Study rule of an unknown field")
    check(len(rule_ids) == len(rules), "Duplicate study rule")
    topic_ids, targets = set(), set()
    for item in topics:
        keys(item, TOPIC_KEYS, "Unexpected lesson topic fields")
        topic_ids.add(uuid_string(item["id"]))
        targets.add(note_target(item["target"], version))
        topic = item.get("topic", "")
        check(isinstance(topic, str) and len(topic) <= 200 and "\n" not in topic, "Invalid lesson topic")
        check(isinstance(item.get("summary", ""), str) and len(item.get("summary", "")) <= 2000, "Invalid key sentence")
        materials = item.get("materials", [])
        check(isinstance(materials, list) and len(materials) <= MAXIMUM_MATERIALS, "Invalid pinned material")
        pinned = set()
        for material in materials:
            keys(material, MATERIAL_KEYS, "Unexpected pinned material fields")
            check(isinstance(material["package"], str) and PACKAGE.fullmatch(material["package"]) is not None, "Invalid material package")
            text(material["key"], 3, 200, "Invalid material key")
            check("\n" not in material["key"], "Invalid material key")
            text(material["label"], 1, 300, "Invalid material label")
            if material.get("detail") is not None:
                text(material["detail"], 0, 300, "Invalid material detail")
            pinned.add((material["package"], material["key"]))
        check(len(pinned) == len(materials), "Duplicate pinned material")
        foundation_date(item["modifiedAt"])
    check(len(topic_ids) == len(topics) and len(targets) == len(topics), "Duplicate lesson topic")
    subjects = state.get("subjectNotebooks", [])
    check(isinstance(subjects, list), "Invalid subject notebooks")
    check(version >= 6 or not subjects, "Subject notebooks before calendar format 6")
    check(len(subjects) <= MAXIMUM_SUBJECTS, "Too many subject notebooks")
    subject_ids, subject_keys, subject_notebooks = set(), set(), []
    for item in subjects:
        keys(item, SUBJECT_KEYS, "Unexpected subject notebook fields")
        subject_ids.add(uuid_string(item["id"]))
        text(item["subjectKey"], 1, 300, "Invalid subject notebook subject")
        title(item["subjectName"])
        subject_keys.add(item["subjectKey"])
        subject_notebooks.append(uuid_string(item["notebookID"]))
    check(len(subject_ids) == len(subjects) and len(subject_keys) == len(subjects)
          and len(set(subject_notebooks)) == len(subjects), "Duplicate subject notebook")
    check(not (set(subject_notebooks) & set(notebooks)), "A subject notebook is a study field's notebook")
    return notebooks + subject_notebooks


def system_key(anchor):
    """Like Swift `CalendarSystemAnchor.key`: external id (blank = none) or
    item id, then the local occurrence or the occurrence in whole seconds."""
    external = (anchor.get("externalID") or "").strip()
    identity = "x:" + anchor["externalID"] if external else "i:" + anchor["itemID"]
    local = (anchor.get("occurrenceLocal") or "").strip()
    if local:
        occurrence = "l" + anchor["occurrenceLocal"]
    elif anchor.get("occurrence") is not None:
        value = anchor["occurrence"]
        occurrence = str(int(math.copysign(math.floor(abs(value) + 0.5), value)))
    else:
        occurrence = "-"
    return identity + "/" + occurrence


def mapping(value):
    keys(value, MAPPING_KEYS, "Unexpected lesson mapping fields")
    uuid_string(value["id"])
    text(value["source"], 1, 300, "Invalid mapping source")
    text(value["fromPeriodID"], 1, 100, "Invalid mapping")
    text(value["toPeriodID"], 1, 100, "Invalid mapping")
    check(value["fromPeriodID"] != value["toPeriodID"], "Mapping onto itself")
    civil(value["fromDate"]); civil(value["toDate"]); foundation_date(value["confirmedAt"])


@strict
def validate_state(state, formats=(1, 2, 3, 4, 5, 6)):
    """Returns (summary counts, document ids of all links, notes folder, connection id)."""
    keys(state, STATE_KEYS, "Unexpected calendar state fields")
    version = state["formatVersion"]
    check(type(version) is int and version in formats, f"Unsupported calendar format {version}")
    events = state["events"]
    check(isinstance(events, list) and len(events) <= MAXIMUM_EVENTS, "Too many events")
    ids = [event(item, version) for item in events]
    check(len(set(ids)) == len(ids), "Duplicate event identity")
    folder = settings(state.get("settings", {}), version)
    connection_id = connection(state["connection"], version) if state.get("connection") is not None else None
    links = state.get("noteLinks", [])
    check(isinstance(links, list) and len(links) <= MAXIMUM_LINKS and (version >= 2 or not links), "Invalid note links")
    documents = [link(item, version) for item in links]
    check(len({item["id"] for item in links}) == len(links), "Duplicate note link")
    mappings = state.get("lessonMappings", [])
    check(isinstance(mappings, list) and len(mappings) <= MAXIMUM_MAPPINGS and (version >= 2 or not mappings), "Invalid mappings")
    for item in mappings:
        mapping(item)
    check(len({item["id"] for item in mappings}) == len(mappings), "Duplicate lesson mapping")
    deleted = state.get("deletedEvents", [])
    check(isinstance(deleted, list) and len(deleted) <= MAXIMUM_DELETED and (version >= 3 or not deleted), "Invalid deleted events")
    for item in deleted:
        keys(item, DELETED_KEYS, "Unexpected deleted event fields")
        uuid_string(item["id"])
        event_id = event(item["event"], version)
        foundation_date(item["deletedAt"])
        if item.get("occurrence") is None:
            check(event_id not in ids, "Event both active and deleted")
        else:
            civil(item["occurrence"])
            check(item["event"].get("recurrence") is not None, "Deleted occurrence without series")
    check(len({item["id"] for item in deleted}) == len(deleted), "Duplicate deleted event")
    marks = state.get("homeworkDone", [])
    check(isinstance(marks, list) and len(marks) <= MAXIMUM_MARKS and (version >= 4 or not marks), "Invalid homework marks")
    for item in marks:
        keys(item, MARK_KEYS, "Unexpected homework mark fields")
        text(item["source"], 1, 300, "Invalid homework source")
        text(item["homeworkID"], 1, 100, "Invalid homework id")
        foundation_date(item["doneAt"])
    check(len({(item["source"], item["homeworkID"]) for item in marks}) == len(marks), "Duplicate homework mark")
    notebooks = study(state, version)
    summary = {"formatVersion": version, "events": len(events), "series": sum(e.get("recurrence") is not None for e in events),
               "reminders": sum(e.get("reminderMinutes") is not None for e in events), "noteLinks": len(links),
               "lessonMappings": len(mappings), "deletedEvents": len(deleted), "connection": connection_id is not None,
               "lessonReminder": state.get("settings", {}).get("lessonReminderMinutes") is not None,
               "homeworkDone": len(marks), "systemCalendars": state.get("settings", {}).get("systemCalendars") is not None,
               "systemNotes": sum(item["target"]["kind"] == "system" for item in links),
               "studyFields": len(state.get("studyFields", [])), "studyRules": len(state.get("studyRules", [])),
               "lessonTopics": len(state.get("lessonTopics", [])), "subjectNotebooks": len(state.get("subjectNotebooks", []))}
    return summary, set(documents) | set(notebooks), folder, connection_id


@strict
def validate_source(source, connection_id):
    """The WebUntis offline timetable of `connection_id` (cache format 1)."""
    keys(source, {"formatVersion", "connection", "lessons", "days", "holidays", "holidaysFetchedAt", "homework"}, "Unexpected timetable fields")
    check(source["formatVersion"] == SOURCE_FORMAT, "Unsupported timetable format")
    check(connection_id is not None and uuid_string(source["connection"]) == connection_id, "Timetable of another connection")
    days = source["days"]
    check(isinstance(days, dict) and len(days) <= 2400, "Invalid loaded days")
    for key, value in days.items():
        civil(key); foundation_date(value)
    lessons = source["lessons"]
    check(isinstance(lessons, list) and len(lessons) <= 80_000, "Too many lessons")
    seen = set()
    for lesson in lessons:
        key = lesson["key"]
        check(uuid_string(key["connection"]) == connection_id, "Lesson of another connection")
        text(key["sourceID"], 1, 200, "Invalid lesson id")
        identity = (key["sourceID"], key["originalStart"])
        check(identity not in seen, "Duplicate lesson")
        seen.add(identity)
        check(civil(lesson["date"]) in days, "Lesson on a day that was never loaded")
        check(number(lesson["start"]) and number(lesson["end"]) and lesson["end"] >= lesson["start"], "Invalid lesson time")
    holidays = source["holidays"]
    check(isinstance(holidays, list) and len(holidays) <= 2000, "Invalid holidays")
    for holiday in holidays:
        check(civil(holiday["end"]) > civil(holiday["start"]), "Invalid holiday")
    if source.get("holidaysFetchedAt") is not None:
        foundation_date(source["holidaysFetchedAt"])
    homework = source.get("homework", [])
    check(isinstance(homework, list) and len(homework) <= 10_000, "Invalid homework")
    for item in homework:
        keys(item, HOMEWORK_KEYS, "Unexpected homework fields")
        text(item["id"], 1, 100, "Invalid homework id")
        text(item["periodID"], 1, 100, "Invalid homework period")
        check(civil(item["periodDate"]) in days, "Homework on a day that was never loaded")
        civil(item["due"])
        if item.get("assigned") is not None:
            check(civil(item["assigned"]) <= item["due"], "Homework given after it is due")
        text(item["text"], 0, 20_000, "Invalid homework text")
        # Same limits as CalendarHomework.isValid.
        for key, limit in (("lessonID", 100), ("subject", 300), ("subjectID", 100), ("remark", 20_000)):
            if item.get(key) is not None:
                text(item[key], 0, limit, "Invalid homework " + key)
        check(type(item["completedInSource"]) is bool and type(item["attachmentCount"]) is int
              and 0 <= item["attachmentCount"] <= 10_000, "Invalid homework flags")
    check(len({item["id"] for item in homework}) == len(homework), "Duplicate homework")
    stamps = list(days.values())
    return {"lessons": len(lessons), "loadedDays": len(days), "holidays": len(holidays), "homework": len(homework),
            "oldestFetch": min(stamps) if stamps else None, "newestFetch": max(stamps) if stamps else None}
