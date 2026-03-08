/**
 * Tests for WF-01b — "Classify Attachment" Code node logic.
 *
 * Tests multi-XLSX filtering by filename keywords and XLSX detection.
 * Run with: node --test tests/test_classify_attachment.mjs
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');
const WF_PATH = resolve(ROOT, 'workflows/test/medika-preorders/01b_process_email.json');

function loadClassifyCode() {
  const wf = JSON.parse(readFileSync(WF_PATH, 'utf8'));
  const node = wf.nodes.find(n => n.name === 'Classify Attachment');
  if (!node) throw new Error('Node "Classify Attachment" not found');
  return node.parameters.jsCode;
}

// Execute with simulated n8n context
function runClassify(binaryAttachments, emailSubject = 'Test', emailBody = '') {
  const code = loadClassifyCode();

  // Build binary object from array of {key, fileName, mimeType}
  const binary = {};
  for (const att of binaryAttachments) {
    binary[att.key] = {
      fileName: att.fileName,
      mimeType: att.mimeType || 'application/octet-stream',
    };
  }

  // Mock n8n functions
  const fetchEmailFirst = {
    json: { body: { content: emailBody } },
    binary,
  };
  const inputFirst = {
    json: { emailSubject },
  };

  const $ = (nodeName) => {
    if (nodeName === 'Fetch Email') return { first: () => fetchEmailFirst };
    throw new Error(`Unknown node: ${nodeName}`);
  };
  const $input = { first: () => inputFirst };

  const wrapped = new Function('$', '$input', `
    ${code.replace(/return \[/g, 'return [')}
  `);

  const result = wrapped($, $input);
  return result[0].json;
}

describe('Classify Attachment', () => {

  describe('XLSX detection', () => {

    it('should detect single XLSX by extension', () => {
      const result = runClassify([
        { key: 'att_0', fileName: 'order.xlsx', mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' },
      ]);

      assert.equal(result._hasXlsx, true);
      assert.equal(result._xlsxCount, 1);
      assert.equal(result._selectedXlsxKey, 'att_0');
    });

    it('should detect XLS by extension', () => {
      const result = runClassify([
        { key: 'att_0', fileName: 'order.xls', mimeType: 'application/vnd.ms-excel' },
      ]);

      assert.equal(result._hasXlsx, true);
      assert.equal(result._xlsxCount, 1);
    });

    it('should not count image attachments as XLSX', () => {
      const result = runClassify([
        { key: 'att_0', fileName: 'image001.png', mimeType: 'image/png' },
        { key: 'att_1', fileName: 'logo.jpg', mimeType: 'image/jpeg' },
      ]);

      assert.equal(result._hasXlsx, false);
      assert.equal(result._xlsxCount, 0);
      assert.equal(result._selectedXlsxKey, null);
    });

    it('should handle no attachments', () => {
      const result = runClassify([]);

      assert.equal(result._hasXlsx, false);
      assert.equal(result._xlsxCount, 0);
    });
  });

  describe('Multi-XLSX title filtering', () => {

    it('should pick XLSX with prednarudžba in filename', () => {
      const result = runClassify([
        { key: 'att_0', fileName: 'Račun.pdf', mimeType: 'application/pdf' },
        { key: 'att_1', fileName: 'PREDNARUDŽBA MEDIKA 16 - 06.03.2026.xlsx' },
        { key: 'att_2', fileName: 'NALOG MEDIKA 16 - 06.03.2026.xlsx' },
      ]);

      assert.equal(result._xlsxCount, 2);
      assert.equal(result._selectedXlsxKey, 'att_1');
    });

    it('should pick XLSX with narudžba in filename', () => {
      const result = runClassify([
        { key: 'att_0', fileName: 'Narudžba.xlsx' },
        { key: 'att_1', fileName: 'Faktura.xlsx' },
      ]);

      assert.equal(result._xlsxCount, 2);
      assert.equal(result._selectedXlsxKey, 'att_0');
    });

    it('should pick XLSX with transfer order in filename', () => {
      const result = runClassify([
        { key: 'att_0', fileName: 'Report Q1.xlsx' },
        { key: 'att_1', fileName: 'Transfer order 06.03.2026.xlsx' },
      ]);

      assert.equal(result._xlsxCount, 2);
      assert.equal(result._selectedXlsxKey, 'att_1');
    });

    it('should pick XLSX with TO prefix in filename', () => {
      const result = runClassify([
        { key: 'att_0', fileName: 'TO MEDIKA - MediLigo.xlsx' },
        { key: 'att_1', fileName: 'Catalogue.xlsx' },
      ]);

      assert.equal(result._xlsxCount, 2);
      assert.equal(result._selectedXlsxKey, 'att_0');
    });

    it('should fall back to first XLSX when no keyword match', () => {
      const result = runClassify([
        { key: 'att_0', fileName: 'Data1.xlsx' },
        { key: 'att_1', fileName: 'Data2.xlsx' },
      ]);

      assert.equal(result._xlsxCount, 2);
      assert.equal(result._selectedXlsxKey, 'att_0');
    });

    it('should handle single XLSX without keyword filtering', () => {
      const result = runClassify([
        { key: 'att_0', fileName: 'image001.png', mimeType: 'image/png' },
        { key: 'att_1', fileName: 'RandomName.xlsx' },
      ]);

      assert.equal(result._xlsxCount, 1);
      assert.equal(result._selectedXlsxKey, 'att_1');
    });
  });
});
