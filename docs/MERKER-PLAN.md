# Merker und Gesetzesverweise – Plan

Stand: 06.11.2026. Diesen Plan hat der Nutzer im Gespräch abgestimmt. Implementiert ist bisher nur **P1** ([PARAGRAPH-LINKS](PARAGRAPH-LINKS.md)). Alles Weitere ist geplant und nicht umgesetzt.

## Ziel

Gedacht für den Alltag in einer **Steuerkanzlei**: Aufgaben, die der Chef nebenbei verteilt, Fristen und Dinge, die man im Kopf behalten muss. Die Schule kommt erst danach. Zwei Bausteine:

1. **Gesetzesverweise im Heft (P):** „§ 35a EStG“, „R 9.1 LStR“ und „AEAO zu § 122“ in Notizen und PDFs werden zu Links. Hovert man mit dem Apple Pencil Pro oder dem Trackpad darüber, erscheint eine Vorschau. Klicken oder Tippen öffnet die Stelle im Gesetzesfenster.
2. **Merker (M):** ein kleines Fenster im Heft (⇧⌘M), das sich mit dem Gesetzesfenster eine Randseite teilt (Tabs „Gesetze | Merker“). Dort stehen Aufgaben mit Mandant, Steuerart/Jahr, Auftraggeber, Frist und Vorfrist sowie Status.

## Pakete

| Paket | Inhalt | Stand |
| --- | --- | --- |
| P1 | §-Erkenner in Core, Links in Textfeldern/Fließtext/PDF-Text, Hover-Vorschau, Öffnen, „Zurück zur Notiz“ | implementiert, siehe PARAGRAPH-LINKS |
| P2 | Querverweise im Gesetzesleser, Tippvorschlag beim Schreiben von „§ …“, Standardgesetz pro Heft, Fassung nach Veranlagungsjahr | geplant |
| M1 | Merker-Fenster mit Tabs. Aufgabe: Text oder Handschrift, Mandant (optional Mandantennummer), Steuerart/Jahr, von wem, Frist und Vorfrist, Status (offen, in Arbeit, wartet auf Belege, wartet auf Finanzamt, erledigt), Erinnerungen, eigenes Paket je Bereich mit Revisionen, Papierkorb, Bibliotheksbackup und Python-Prüfer | geplant |
| M2 | Einspruchsfrist-Hilfe (Bekanntgabe nach 4 Tagen gemäß § 122 Abs. 2 AO, dann + 1 Monat gemäß § 355 AO, Verschiebung nach § 108 Abs. 3 AO auf den nächsten Werktag in NRW; deutlich als **Hilfsrechnung** beschriftet), Vorlagen für UStVA/LStA/ESt-Vorauszahlungen, Nachfassen bei „wartet auf Belege“, Ansicht nach Mandant, offene ☐-Aufgaben aus Heften übernehmen | geplant |
| P3 | §-Erkennung in Handschrift (vorhandene OCR der Suche), nur mit Rückfrage „erkannt: … – stimmt das?“ | geplant |
| M3 | Lasso „Als Aufgabe merken“ mit Rücksprung zur Seite, Fristen im Kalender (`feat/kalender`), optional Outlook über EventKit | geplant |

## Feste Regeln

- **Verschwiegenheit:** Mandantendaten bleiben lokal und in den eigenen Backups. Sie gehen nicht in den Abgleich zu noty AI und nicht an die KI-Bridge. Im öffentlichen Repo stehen nur erfundene Testmandanten.
- **Kein Ersatz für die Fristenkontrolle der Kanzlei** (Kanzleisoftware, Fristenbuch). In der App heißt das persönlicher Helfer. Eine DATEV-Anbindung ist nicht geplant.
- Squeeze am Pencil bleibt die Werkzeugpalette, Doppeltippen der Werkzeugwechsel. Der Stift auf dem Papier öffnet nie etwas.
- Arbeitsablauf wie in AGENTS.md: `feat/*` von `dev`, Test in noty dev, `main` nur nach Freigabe.

## Offene Fragen an den Nutzer

- Welche Steuerarten und Tätigkeiten am häufigsten vorkommen (davon hängen die Vorlagen in M2 ab).
- Mandantennummer als eigenes Feld oder nur Name.
- Ob Merker in noty dev testweise mit echten Daten gespiegelt werden dürfen.
- Ob Fristen ins Outlook-Arbeitskonto gehen sollen.
