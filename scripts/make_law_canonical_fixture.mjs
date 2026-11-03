// Erzeugt Core/Tests/Fixtures/law-canonical.json aus der Kanonisierung der
// Website (lib/annotations.ts) und des Kontodiensts (server/api.mjs).
// Beide Quellen werden nur gelesen. Aufruf aus dem Projektroot:
//
//   node --experimental-strip-types scripts/make_law_canonical_fixture.mjs \
//     [../gesetzessammlung-noty] [Core/Tests/Fixtures/law-canonical.json]
//
// Bricht ab, wenn Website und Server für eine Eingabe verschieden kanonisieren.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const source = resolve(process.argv[2] ?? '../gesetzessammlung-noty');
const target = resolve(process.argv[3] ?? 'Core/Tests/Fixtures/law-canonical.json');
const web = await import(pathToFileURL(resolve(source, 'lib/annotations.ts')).href);

// The server keeps `canonical` module-private: take its exact one-line definition.
const api = readFileSync(resolve(source, 'server/api.mjs'), 'utf8');
const line = api.match(/^const canonical = (\(text\) => .+);$/m);
if (!line) throw new Error('server/api.mjs: Definition von canonical nicht gefunden');
const serverCanonical = new Function(`return ${line[1]}`)();

const inputs = [
  ['ascii', '§ 4a Abs. 2 HGB'],
  ['paragraph-sentence', '(1) Der Kaufmann ist verpflichtet, Bücher zu führen.'],
  ['ligature-fi', 'ﬁnanzieren'],
  ['ligature-ffi', 'Ä ﬃ 𝟙!'],
  ['capital-sharp-s', 'STRAẞE'],
  ['sharp-s', 'Straße'],
  ['umlauts-precomposed', 'Ärger Öl Übung'],
  ['umlauts-decomposed', 'Ärger Öl Übung'],
  ['accents', 'Café crème à la française'],
  ['stacked-marks', 'é̂x'],
  ['leading-marks', '́̂ab'],
  ['emoji', '😀 A 👍🏽 b'],
  ['emoji-zwj', 'x👩‍👩‍👧y'],
  ['flag', 'de🇩🇪en'],
  ['fraktur', '𝔘𝔫𝔦𝔬𝔫'],
  ['dotted-capital-i', 'İstanbul'],
  ['dz-digraph', 'ǄǅǆDŽ'],
  ['roman-numeral', 'Ⅻ Ⅳ ⅷ'],
  ['fraction', '½ ¾'],
  ['circled', '① ⑳'],
  ['superscript', 'm² x³'],
  ['crlf', 'Satz 1\r\nSatz 2\rSatz 3\n'],
  ['tabs-nbsp', 'a\tb c d'],
  ['soft-hyphen', 'Rechts­anwalt'],
  ['zero-width', 'ab​cd‍de﻿'],
  ['section-reference', '§§ 4a Abs. 2 Satz 3 Nr. 1 Buchst. b UStG'],
  ['greek-final', 'ΟΔΟΣ'],
  ['greek-odysseus', 'ὈΔΥΣΣΕΎΣ'],
  ['greek-sigma-alone', 'Σ'],
  ['greek-sigma-words', 'ΑΣ ΒΣ.Γ ΔΣ\'Ε ΖΣ1'],
  ['greek-sigma-mark', 'ΑΣ́ Β'],
  ['greek-lower', 'σοφός'],
  ['hangul-jamo', '각 가'],
  ['devanagari', 'क्षत्रिय'],
  ['arabic', 'القانون ١٢٣'],
  ['hebrew', 'חוק 5'],
  ['cjk', '民法第一条'],
  ['fullwidth', 'ＡＢＣ１２３'],
  ['math-digits', '𝟎𝟏𝟐'],
  ['kelvin-angstrom', 'K Å'],
  ['ohm-micro', 'Ω µ'],
  ['long-s', 'ſ'],
  ['turkish-dotless', 'ı I'],
  ['armenian-ligature', 'ﬓ'],
  ['punctuation-only', '–„“‚‘…§%/'],
  ['empty', ''],
  ['digits-mixed', '2026-11-03 12:30 Uhr'],
  ['modifier-letters', 'ʰʲ ᵃ'],
  ['vulgar-dot', 'Abs. 2a), b)'],
  ['mixed-long', '(2) ¹Die Vorschrift gilt für Ärzte, Ǆemal-Zentren & ΟΔΟΣ-Büros; ²ﬁnal: ½ Ⅻ ①.'],
];

const utf16 = (s) => Array.from({ length: s.length }, (_, i) => s.charCodeAt(i));

function pairs(text) {
  const n = text.length;
  const result = [];
  if (n <= 16) {
    for (let start = 0; start < n; start++)
      for (let end = start + 1; end <= n; end++) result.push([start, end]);
  } else {
    // Deterministic sample: every start with a few lengths, plus the whole text.
    for (let start = 0; start < n; start += 3)
      for (const length of [1, 2, 5, 11])
        if (start + length <= n) result.push([start, start + length]);
    result.push([0, n]);
  }
  return result;
}

const cases = inputs.map(([name, input]) => {
  const canonical = web.canonicalText(input);
  const server = serverCanonical(input);
  if (canonical !== server) throw new Error(`Website und Server weichen ab bei ${name}`);
  const map = web.canonicalMap(input);
  const section = { id: 's', text: input };
  const anchors = pairs(input).map(([start, end]) => ({
    start, end, anchor: web.anchorFromSelection(section, input, start, end),
  }));
  return {
    name,
    input,
    inputUTF16: utf16(input),
    canonical,
    canonicalUTF16: utf16(canonical),
    map: map && { starts: map.starts, ends: map.ends },
    anchors: anchors.map(({ start, end, anchor }) => ({
      start, end,
      anchor: anchor && { start: anchor.start, end: anchor.end, quote: anchor.quote },
    })),
  };
});

// Rendered text differing from the stored section text: only a unique quote bridges.
const bridged = [
  ['table-unique', 'Spalte A | Spalte B', 'Spalte A Spalte B Ende', 11, 19],
  ['table-ambiguous', 'ab ab', 'ab ab ab', 0, 2],
  ['table-missing', 'xyz', 'abc', 0, 3],
].map(([name, rendered, sectionText, start, end]) => {
  const anchor = web.anchorFromSelection({ id: 's', text: sectionText }, rendered, start, end);
  return { name, rendered, sectionText, start, end, anchor: anchor && { start: anchor.start, end: anchor.end, quote: anchor.quote } };
});

const fixture = {
  generatedBy: 'scripts/make_law_canonical_fixture.mjs',
  source: 'gesetzessammlung-noty lib/annotations.ts canonicalText/canonicalMap/anchorFromSelection, server/api.mjs canonical',
  node: process.version,
  icu: process.versions.icu,
  unicode: process.versions.unicode,
  cases,
  bridged,
};
mkdirSync(dirname(target), { recursive: true });
writeFileSync(target, JSON.stringify(fixture, null, 1) + '\n');
console.log(`${cases.length} Eingaben, ${cases.reduce((n, c) => n + c.anchors.length, 0)} Auswahlbereiche → ${target}`);
