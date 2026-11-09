#!/usr/bin/env python3
"""Host roundtrip, Kalender B3: checks the calendar artefacts written by
CalendarBackupCheck.swift independently and rejects mutated copies.

    check_calendar_backup.py RESULTS

RESULTS holds `kalender.notylibrary` (library archive format 3), the source
area `Kalender/` and `kalender-restore-path.txt` (data root of the restored
area). Mutations are rebuilt with fresh CRCs, so only the calendar checks can
reject them. Prints counts only, never contents. Exit code 1 on any failure.
"""
import json
import struct
import sys
import zlib
from pathlib import Path

import verify_device_store
import verify_library_backup
from notebook_format import check

SECRETS = (b"erfunden-geheim", b"example.invalid", b"max.erfunden", b"JBSWY3DPEHPK3PXPGEHEIMGEHEIM")


def records(data):
    """(header, [[descriptor, payload]]) of a record stream."""
    offset = 8

    def take(count):
        nonlocal offset
        offset += count
        return data[offset - count:offset]

    header = json.loads(take(struct.unpack(">I", take(4))[0]))
    items = []
    while True:
        descriptor = json.loads(take(struct.unpack(">I", take(4))[0]))
        if descriptor["kind"] == "end":
            return header, items
        items.append([descriptor, take(descriptor["byteCount"])])


def stream(header, items):
    def prefixed(value):
        encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        return struct.pack(">I", len(encoded)) + encoded

    out = b"NOTYLIB\n" + prefixed(header)
    for descriptor, payload in items:
        if "crc32" in descriptor:
            descriptor = dict(descriptor, crc32=zlib.crc32(payload), byteCount=len(payload))
        out += prefixed(descriptor) + payload
    return out + prefixed({"kind": "end", "records": len(items), "payloadBytes": sum(len(p) for _, p in items)})


def main(results):
    raw = (results / "kalender.notylibrary").read_bytes()
    archive = verify_library_backup.verify(results / "kalender.notylibrary")
    calendar = archive["calendar"]
    check(archive["formatVersion"] == 3 and calendar["events"] == 1 and calendar["series"] == 1 and calendar["noteLinks"] == 3
          and calendar["formatVersion"] == 6 and calendar["systemNotes"] == 1 and calendar["subjectNotebooks"] == 1
          and calendar["studyFields"] == 1 and calendar["studyRules"] == 1 and calendar["lessonTopics"] == 1 and calendar["systemCalendars"]
          and calendar["homeworkDone"] == 1 and calendar["timetable"]["homework"] == 1
          and calendar["deletedEvents"] == 2 and calendar["lessonMappings"] == 1 and calendar["reminders"] == 1
          and calendar["lessonReminder"] and calendar["connection"] and calendar["timetable"]["lessons"] == 1,
          "Kalenderteil des Archivs unvollständig")
    for secret in SECRETS:
        check(secret not in raw and secret.lower() not in raw, "Zugangsdaten im Archiv")
    _, source = verify_device_store.load_store(results / "Kalender")
    _, restored = verify_device_store.load_store(Path((results / "kalender-restore-path.txt").read_text()))
    for store in (source, restored):
        part = store["calendar"]
        check(part["committed"] and part["links_without_notebook"] == 0 and part["notes_folder_present"]
              and part["timetable"]["lessons"] == 1 and part["noteLinks"] == 3 and part["formatVersion"] == 6 and part["subjectNotebooks"] == 1, "Kalenderpaket unvollständig")

    def mutated(name, change_state=None, change_items=None, header_change=None):
        header, items = records(raw)
        if header_change:
            header = dict(header, **header_change)
        if change_state:
            index = next(i for i, (d, _) in enumerate(items) if d["kind"] == "calendar")
            state = json.loads(items[index][1])
            change_state(state)
            items[index][1] = json.dumps(state).encode()
        if change_items:
            change_items(items)
        path = results / name
        path.write_bytes(stream(header, items))
        return path

    # The rebuilt archive itself is valid: only the mutation decides.
    verify_library_backup.verify(mutated("kalender-nachbau.notylibrary"))

    def link_elsewhere(state):
        state["noteLinks"][0]["documentID"] = "00000000-0000-4000-8000-0000000000AA"

    def secret_field(state):
        state["connection"]["key"] = "JBSWY3DPEHPK3PXP"

    def newer(state):
        state["formatVersion"] = 7

    def study_under_format4(state):
        # Lernfelder (format 5) under format 4.
        state["formatVersion"] = 4
        del state["subjectNotebooks"]

    def subjects_under_format5(state):
        # Fach-Hefte (format 6) under format 5.
        state["formatVersion"] = 5

    def subject_of_field_notebook(state):
        state["subjectNotebooks"][0]["notebookID"] = state["studyFields"][0]["notebookID"]

    def downgraded(state):
        # Format-4 fields (system note, homework marks) under format 3.
        state["formatVersion"] = 3

    def secret_in_system_settings(state):
        state["settings"]["systemCalendars"]["password"] = "erfunden"

    def folder_elsewhere(state):
        state["settings"]["notesFolderID"] = "00000000-0000-4000-8000-0000000000BB"

    def no_calendar(items):
        items[:] = [item for item in items if not item[0]["kind"].startswith("calendar")]

    def swapped(items):
        index = next(i for i, (d, _) in enumerate(items) if d["kind"] == "calendar")
        items[index], items[index + 1] = items[index + 1], items[index]

    def foreign_timetable(items):
        index = next(i for i, (d, _) in enumerate(items) if d["kind"] == "calendarSource")
        source = json.loads(items[index][1])
        source["connection"] = "00000000-0000-4000-8000-0000000000CC"
        items[index][1] = json.dumps(source).encode()

    cases = {"Link auf Heft außerhalb des Archivs": mutated("kalender-link.notylibrary", link_elsewhere),
             "Geheimnisfeld in der Verbindung": mutated("kalender-geheim.notylibrary", secret_field),
             "Kalenderformat 7": mutated("kalender-format7.notylibrary", newer),
             "Format-4-Felder unter Format 3": mutated("kalender-format3-mit-4.notylibrary", downgraded),
             "Format-5-Felder unter Format 4": mutated("kalender-format4-mit-5.notylibrary", study_under_format4),
             "Format-6-Felder unter Format 5": mutated("kalender-format5-mit-6.notylibrary", subjects_under_format5),
             "Fach-Heft ist Lernfeld-Heft": mutated("kalender-fachheft-lernfeld.notylibrary", subject_of_field_notebook),
             "Fremdfeld in den Systemkalendern": mutated("kalender-system-feld.notylibrary", secret_in_system_settings),
             "Notizordner außerhalb des Archivs": mutated("kalender-ordner.notylibrary", folder_elsewhere),
             "Format 3 ohne Kalender": mutated("kalender-fehlt.notylibrary", change_items=no_calendar),
             "Stundenplan vor dem Kalender": mutated("kalender-reihenfolge.notylibrary", change_items=swapped),
             "Stundenplan einer anderen Verbindung": mutated("kalender-fremdplan.notylibrary", change_items=foreign_timetable),
             "Bibliotheksformat 4": mutated("kalender-v4.notylibrary", header_change={"libraryBackupVersion": 4})}
    for name, path in cases.items():
        try:
            verify_library_backup.verify(path)
        except ValueError:
            continue
        raise SystemExit("FEHLER: " + name + " wurde akzeptiert")
    print(json.dumps({"calendarArchiveVerifiedByPython": True, "calendar": calendar, "sourceStore": source["calendar"],
                      "restoredStore": restored["calendar"], "rejectedCalendarMutations": len(cases)}, ensure_ascii=False))


if __name__ == "__main__":
    main(Path(sys.argv[1]))
