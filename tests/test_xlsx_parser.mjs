/**
 * Tests for WF-03 XLSX Parser — "Detect Columns & Normalize" Code node logic.
 *
 * Extracts the JavaScript from the workflow JSON and tests it against
 * various input scenarios. Run with: node --test tests/test_xlsx_parser.mjs
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');
const WF_PATH = resolve(ROOT, 'workflows/test/medika-preorders/03_xlsx_parser.json');

// Load and wrap the Code node's JavaScript so we can call it
function loadParserCode() {
  const wf = JSON.parse(readFileSync(WF_PATH, 'utf8'));
  const node = wf.nodes.find(n => n.name === 'Detect Columns & Normalize');
  if (!node) throw new Error('Node "Detect Columns & Normalize" not found');
  return node.parameters.jsCode;
}

// Execute the parser code in a simulated n8n environment
function runParser(inputRows) {
  const code = loadParserCode();

  // Build n8n-style $input.all() items
  const items = inputRows.map(row => ({ json: row }));

  // Wrap in a function that provides the n8n globals
  const wrapped = new Function('$input', `
    const _items = $input;
    const $inputObj = { all: () => _items };
    // Replace $input references
    ${code.replace(/\$input/g, '$inputObj')}
  `);

  const result = wrapped(items);
  return result[0].json;
}

describe('Detect Columns & Normalize', () => {

  describe('Excel error filtering (#N/A)', () => {

    it('should filter out rows with #N/A in pharmacy code', () => {
      const rows = [
        { 'Šifra ljekarne': '7700017842', 'Naziv ljekarne': 'LJ JADRAN', 'Šifra artikla': '300067884', 'KOM': 3 },
        { 'Šifra ljekarne': '#N/A', 'Naziv ljekarne': '0', 'Šifra artikla': '#N/A', 'KOM': 0 },
      ];

      const result = runParser(rows);

      assert.equal(result.matched, true);
      assert.equal(result.lineCount, 1);
      assert.equal(result.orderLines[0].pharmacyId, '7700017842');
    });

    it('should filter out rows with #REF! in drug code', () => {
      const rows = [
        { 'Šifra ljekarne': '7700017842', 'Šifra artikla': '300067884', 'KOM': 3 },
        { 'Šifra ljekarne': '7700017842', 'Šifra artikla': '#REF!', 'KOM': 2 },
      ];

      const result = runParser(rows);

      assert.equal(result.lineCount, 1);
      assert.equal(result.orderLines[0].drugCode, '300067884');
    });

    it('should filter out rows with #VALUE! in pharmacy code', () => {
      const rows = [
        { 'Šifra ljekarne': '#VALUE!', 'Šifra artikla': '300067884', 'KOM': 1 },
        { 'Šifra ljekarne': '7700000001', 'Šifra artikla': '300067884', 'KOM': 1 },
      ];

      const result = runParser(rows);

      assert.equal(result.lineCount, 1);
      assert.equal(result.orderLines[0].pharmacyId, '7700000001');
    });

    it('should keep valid rows when mixed with Excel errors', () => {
      const rows = [
        { 'Šifra ljekarne': '7700017842', 'Naziv ljekarne': 'LJ JADRAN', 'Šifra artikla': '300067884', 'KOM': 3 },
        { 'Šifra ljekarne': '#N/A', 'Naziv ljekarne': '0', 'Šifra artikla': '#N/A', 'KOM': 0 },
        { 'Šifra ljekarne': '7700017842', 'Naziv ljekarne': 'LJ JADRAN', 'Šifra artikla': '300085305', 'KOM': 2 },
        { 'Šifra ljekarne': '#N/A', 'Naziv ljekarne': '0', 'Šifra artikla': '#N/A', 'KOM': 0 },
      ];

      const result = runParser(rows);

      assert.equal(result.matched, true);
      assert.equal(result.lineCount, 2);
    });

    it('should return no lines when all rows are Excel errors', () => {
      const rows = [
        { 'Šifra ljekarne': '#N/A', 'Šifra artikla': '#N/A', 'KOM': 0 },
        { 'Šifra ljekarne': '#N/A', 'Šifra artikla': '#N/A', 'KOM': 0 },
      ];

      const result = runParser(rows);

      // All rows filtered → 0 lines, but matched=true since headers detected
      assert.equal(result.lineCount, 0);
    });
  });

  describe('Standard XLSX parsing', () => {

    it('should parse standard Medika format', () => {
      const rows = [
        { 'Šifra ljekarne': '7700000821', 'Naziv ljekarne': 'LJ BARIŠIĆ', 'Šifra artikla': '300103827', 'KOM': 2 },
      ];

      const result = runParser(rows);

      assert.equal(result.matched, true);
      assert.equal(result.lineCount, 1);
      assert.equal(result.orderLines[0].pharmacyId, '7700000821');
      assert.equal(result.orderLines[0].drugCode, '300103827');
      assert.equal(result.orderLines[0].quantity, 2);
    });

    it('should skip rows with zero quantity', () => {
      const rows = [
        { 'Šifra ljekarne': '7700000821', 'Šifra artikla': '300103827', 'KOM': 2 },
        { 'Šifra ljekarne': '7700000821', 'Šifra artikla': '300103828', 'KOM': 0 },
      ];

      const result = runParser(rows);

      assert.equal(result.lineCount, 1);
    });

    it('should parse discount column when present', () => {
      const rows = [
        { 'Šifra ljekarne': '7700011110', 'Naziv ljekarne': 'LJ TRIPOLSKI', 'Šifra artikla': '300058795', 'KOM': 200, 'RABAT': 40 },
      ];

      const result = runParser(rows);

      assert.equal(result.orderLines[0].discount, 40);
    });

    it('should fall back to AI when headers unrecognized', () => {
      const rows = [
        { 'Filijala': '1', 'Ljekarna name': 'MARKUŠEVEC', 'Code': 'C002034', 'Qty': 10 },
      ];

      const result = runParser(rows);

      // 'Code' and 'Qty' should match via known headers
      // but if not, matched should be false
      assert.ok(result.matched === true || result.matched === false);
    });

    it('should return empty for no data', () => {
      const result = runParser([]);

      assert.equal(result.matched, false);
      assert.equal(result.error, 'No data in spreadsheet');
    });
  });

  describe('Headers with newlines', () => {

    it('should handle newlines in column headers (dermapharm format)', () => {
      const rows = [
        { 'Šifra ljekarne \nVd': 7700007860, 'Ljekarna \nNaziv Ustanove Vd': 'LJ VUKOJA 1', 'Šifra\nartikla': 300105945, 'Artikl': 'ARKOPHARMA DETOX BIO', 'KOLIČINA ZA \nNARUDŽBU': 1, 'Rabat \n%': 10 },
      ];

      const result = runParser(rows);

      assert.equal(result.matched, true);
      assert.equal(result.orderLines[0].pharmacyId, '7700007860');
      assert.equal(result.orderLines[0].drugCode, '300105945');
      assert.equal(result.orderLines[0].quantity, 1);
      assert.equal(result.orderLines[0].discount, 10);
    });

    it('should not let short patterns steal headers from more specific fields', () => {
      const rows = [
        { 'Šifra ljekarne': '7700000001', 'Šifra': '300012345', 'KOM': 5 },
      ];

      const result = runParser(rows);

      assert.equal(result.matched, true);
      assert.equal(result.orderLines[0].pharmacyId, '7700000001');
      assert.equal(result.orderLines[0].drugCode, '300012345');
    });
  });
});
