# Vorschau, Scrollen und Randregler – Korrektur Build 13

Stand 17.10.2026. Nutzerbericht beim ersten Build-12-Gerätetest: PDF-Schreibplatz zeigt dauerhaft Ladekreis, Scrollposition springt selbstständig zurück, Randregler haben versetzte Trefferflächen (Links aktiviert Unten). Screenshot IMG_0235 bestätigt Ladekreis im Randfenster; die kleine Seitenvorschau daneben zeigt PDF-Inhalt. Kein Crash gemeldet.

## Untersuchung

- `PageThumbnail` hatte eine bedingte `Group` (Spinner/Bild/Fehler) mit gemeinsam angehängtem `.task` und `.onDisappear { image=nil }`. Gruppenmodifier wirken auf Mitglieder; beim Austausch Spinner→Bild kann dadurch der Bildzustand erneut gelöscht werden. Konkreter struktureller Lebenszyklusfehler, plausibel für Lade-/Layoutschleife. Die genaue Callbackfolge auf diesem iPad ist nicht per Laufzeittrace bewiesen. Quelle: [Apple Group](https://developer.apple.com/documentation/swiftui/group).
- Sidebar zentrierte per `ScrollViewReader` bei Erscheinen und Seiten-ID-Wechsel ohne ausdrückliche Nutzeraktion. Diese programmgesteuerten Sprünge entfernen.
- Links/Rechts/Oben/Unten verwenden die jeweils richtigen Bindings. Kein vertauschter Variablenzugriff gefunden. Bisherige `Form`-Zeilen fügten bei Toggle zusätzliche Slider/Buttons ein; Bildwechsel und geänderte Zeilenhöhen können die Layout-/Trefferflächenprobleme begünstigen. Ein alleiniger kausaler Nachweis für Links→Unten fehlt; nicht als Pencil-/Speicherfehler einstufen.

## Umsetzung

- Fester UIKit-Vorschaubereich (`UIViewRepresentable` mit eigener UIView, UIImageView, Ladeindikator/Fehlertext), ohne intrinsische Bildgröße. Root, Grenzen und Tasklebenszyklus bleiben beim Bildwechsel gleich. Bildfläche abschneiden und vollständig von Hit-Testing ausschließen. Cache/600-ms-Aktualisierung nach Eingaberuhe bleiben erhalten.
- Sidebar nur noch über ausdrücklichen Footerknopf „Seite x von y“ zentrieren. Keine automatischen Appearance-/Seiten-ID-Sprünge. Papier-Vorlagenpreview ebenfalls mit stabilem Container.
- Randdialog als normaler ScrollView/VStack statt virtualisierter Form. Vier Karten behalten Toggle/Slider/Schnellwerte auch ausgeschaltet bei; ausgeschaltete Regler deaktivieren, keine Kontrollzeilen ein-/ausbauen. Native Switches, explizite Button-/Picker-Stile und feste, nicht bedienbare Vorschaufläche.
- Kein Datenformat-/Koordinaten-/Speicherumbau. Übernehmen/Warnung/Papierkorbsicherung unverändert. Mit demselben ausdrücklich gewünschten Subagenten UI-Anteil/Review bearbeitet; Gesamtbuild/Installation beim Hauptagenten.

## Gesicherter Gerätebestand

Vor Update unter `/home/la/Backups/noty-before-ui-fix-13-2026-10-17T14-02-03Z/Documents/` gesichert: 17 Hefte in fünf Bereichen, 29 referenzierte Revisionen unabhängig CRC-/schemageprüft, 95 Dateien gehasht. Alle 15 vor Build 12 vorhandenen Heftinhalte vollständig gleich zum Vorbestand. Neues Schema-3-Testheft: fünf Seiten, eine Quelle bytegleich zu `Seitenformate.pdf`, Ränder gespeichert, keine nichtleeren Ink-Daten. Das belegt gültigen gespeicherten Teststand, keinen bestandenen Pencil-/Randtest. Berichte `before-inspection.json` und `feedback-inspection.json` im Backup.

## Prüfungen / gezielter Retest

111 Core-Tests weiter bestanden (`.tools/core-tests-ui-fix-13.log`). Swift-Syntax/Whitespace geprüft; Apple-UI-Verhalten daraus nicht ableiten. Abschließender Build 13 mit Swift/xtool/SDK wie Build 12 erfolgreich (12,42 s), signiert/IPA erstellt, keine gemeldeten Warnungen/Fehler (`.tools/ios-build-ui-fix-13-final.log`, `.tools/Noty-build-13.sha256`).

`xtool install --usb xtool/Noty.ipa` mit „Successfully installed!“ abgeschlossen (`.tools/ios-install-ui-fix-13.log`), keine Deinstallation/Identitätsänderung. Nachher vollständige Documents mit frischer AFC-Verbindung nach `after-update/Documents/` im genannten Backup zurückgelesen: alle 17 Hefte vollständig unverändert, alle 95 vorherigen Dateien bytegleich, keine neuen Documents-Dateien (`update-inspection.json`). **Implementiert, gebaut und installiert; UI-Korrektur auf dem iPad noch nicht bestätigt.**

Nach Update nur dieser kurze Retest im vorhandenen Testheft:

1. PDF-Schreibplatz öffnen: wird die Vorschau sichtbar und bleibt sie stehen?
2. Nach unten scrollen, loslassen und kurz warten: bleibt die Scrollposition erhalten?
3. Links/Rechts/Oben/Unten nacheinander ein-/ausschalten, Regler bewegen: reagiert genau das berührte Feld, Vorschau passt? Noch keine vorhandene Rand-Handschrift verkleinern.

Erst nach Bestätigung mit dem übrigen Seiten-/Rand-/Neustart-/Exporttest aus Paket 12 fortfahren. Kein gesamter Wiederholungstest und keine Gerätefreigabe vor Rückmeldung.

## Nutzerrückmeldung und nächste Anpassung

Nutzer bestätigt den gezielten dreiteiligen Retest mit „ja passt“: Vorschau sichtbar, Scrollen ohne ungewollten Rücksprung und Randbedienung passend. Als Nutzerbestätigung protokolliert, kein automatisierter UI-Test und keine Abnahme des restlichen Paket-12-Ablaufs.

Zusätzlich gewünscht für Build 14: Strich in der Seitenleiste entfernen, tatsächliche Seitenproportionen statt weiß gefülltem Vorschau-Außenrahmen, Schnellwerte 25/60/100 %, keine manuelle Sidebargrößenverstellung. Codebefund: `Divider` lag im ZStack-Overlay ohne vertikalen Kontext und konnte quer über die Leiste zeichnen. Divider und Ziehgriff entfernt; neue feste responsive Breite. Vorschauen behalten den stabilen UIKit-Root, erhalten passende Seitenproportionen und nur den tatsächlichen Papierumriss. Kein erneutes Einführen der Group-Ladeschleife.
