"""Independent checks of noty calendar data (Kalender B1-B3), shared by
verify_library_backup.py (archive format 3) and verify_device_store.py
(`<Bereich>/Calendar/` package). Independent of the Swift code; explicit
checks raising ValueError (also under python -O). Never prints contents.

CalendarState formats: 1 (B1: events, settings, connection), 2 (B2: series,
note links, lesson mappings, subject colours, notes folder, source
identity), 3 (B3: reminders, lesson reminder setting, deleted events). The
connection record never contains access data: its keys are exactly the known
non-secret ones. A library archive carries exactly the current format 3.
"""
import re

from notebook_format import check, foundation_date, number, strict, uuid_string

CURRENT_FORMAT = 3
STATE_KEYS = {"formatVersion", "events", "settings", "connection", "noteLinks", "lessonMappings", "deletedEvents"}
EVENT_KEYS = {"id", "title", "location", "details", "timing", "recurrence", "reminderMinutes", "createdAt", "modifiedAt"}
SETTINGS_KEYS = {"weekDays", "mode", "subjectColors", "notesFolderID", "lessonReminderMinutes"}
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


def link(value):
    keys(value, LINK_KEYS, "Unexpected note link fields")
    uuid_string(value["id"])
    target = value["target"]
    check(isinstance(target, dict) and target.get("kind") in ("local", "lesson"), "Invalid note target")
    if target["kind"] == "local":
        keys(target, {"kind", "event", "date"}, "Invalid note target")
        uuid_string(target["event"])
        if target.get("date") is not None:
            civil(target["date"])
    else:
        keys(target, {"kind", "lesson"}, "Invalid note target")
        anchor = target["lesson"]
        keys(anchor, {"source", "periodID", "lessonID", "originalDate", "originalStart"}, "Invalid lesson anchor")
        text(anchor["source"], 1, 300, "Invalid lesson source")
        text(anchor["periodID"], 1, 100, "Invalid lesson period")
        check(anchor.get("lessonID") is None or (isinstance(anchor["lessonID"], str) and len(anchor["lessonID"]) <= 100), "Invalid lesson course")
        civil(anchor["originalDate"]); text(anchor["originalStart"], 0, 40, "Invalid lesson start")
    if value.get("pageID") is not None:
        uuid_string(value["pageID"])
    check(type(value["hasContent"]) is bool, "Invalid note content flag")
    text(value["contextTitle"], 1, 300, "Invalid note context")
    for key in ("createdAt", "contextStart", "contextEnd"):
        foundation_date(value[key])
    check(value["contextEnd"] >= value["contextStart"], "Invalid note context time")
    return uuid_string(value["documentID"])


def mapping(value):
    keys(value, MAPPING_KEYS, "Unexpected lesson mapping fields")
    uuid_string(value["id"])
    text(value["source"], 1, 300, "Invalid mapping source")
    text(value["fromPeriodID"], 1, 100, "Invalid mapping")
    text(value["toPeriodID"], 1, 100, "Invalid mapping")
    check(value["fromPeriodID"] != value["toPeriodID"], "Mapping onto itself")
    civil(value["fromDate"]); civil(value["toDate"]); foundation_date(value["confirmedAt"])


@strict
def validate_state(state, formats=(1, 2, 3)):
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
    documents = [link(item) for item in links]
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
    summary = {"formatVersion": version, "events": len(events), "series": sum(e.get("recurrence") is not None for e in events),
               "reminders": sum(e.get("reminderMinutes") is not None for e in events), "noteLinks": len(links),
               "lessonMappings": len(mappings), "deletedEvents": len(deleted), "connection": connection_id is not None,
               "lessonReminder": state.get("settings", {}).get("lessonReminderMinutes") is not None}
    return summary, set(documents), folder, connection_id


@strict
def validate_source(source, connection_id):
    """The WebUntis offline timetable of `connection_id` (cache format 1)."""
    keys(source, {"formatVersion", "connection", "lessons", "days", "holidays", "holidaysFetchedAt"}, "Unexpected timetable fields")
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
    stamps = list(days.values())
    return {"lessons": len(lessons), "loadedDays": len(days), "holidays": len(holidays),
            "oldestFetch": min(stamps) if stamps else None, "newestFetch": max(stamps) if stamps else None}
