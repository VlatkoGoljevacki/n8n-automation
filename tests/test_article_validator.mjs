/**
 * Tests for WF-04 Data Validator — "Validate Required Fields" Code node logic.
 *
 * Run with: node --test tests/test_article_validator.mjs
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');
const WF_PATH = resolve(ROOT, 'workflows/test/medika-preorders/04_article_validator.json');

function loadValidatorCode() {
  const wf = JSON.parse(readFileSync(WF_PATH, 'utf8'));
  const node = wf.nodes.find(n => n.name === 'Validate Required Fields');
  if (!node) throw new Error('Node "Validate Required Fields" not found');
  return node.parameters.jsCode;
}

function runValidator(orderLines, customerLookup = {}) {
  const code = loadValidatorCode();

  const input = {
    orderLines,
    defaultDiscountPerc: 0,
    customerLookup: {
      customerById: {},
      deliveryPlaceById: {},
      ...customerLookup,
    },
  };

  const $input = { first: () => ({ json: input }) };

  const wrapped = new Function('$input', `
    const $inputObj = $input;
    ${code.replace(/\$input/g, '$inputObj')}
  `);

  return wrapped($input)[0].json;
}

const VALID_LOOKUP = {
  deliveryPlaceById: {
    '7700000821': { customerId: 'C001', customerName: 'Test Customer', name: 'LJ TEST' },
  },
};

describe('Validate Required Fields', () => {

  describe('article code validation', () => {

    it('should accept Medika article codes starting with digits', () => {
      const result = runValidator([
        { drugCode: '300103827', quantity: 2, pharmacyId: '7700000821' },
      ], VALID_LOOKUP);

      assert.equal(result.summary.valid, 1);
      assert.equal(result.summary.invalid, 0);
    });

    it('should accept gratis codes starting with 930', () => {
      const result = runValidator([
        { drugCode: '930006180', quantity: 1, pharmacyId: '7700000821' },
      ], VALID_LOOKUP);

      assert.equal(result.summary.valid, 1);
    });

    it('should reject non-Medika codes not starting with digit', () => {
      const result = runValidator([
        { drugCode: 'C002034', quantity: 10, pharmacyId: '7700000821' },
      ], VALID_LOOKUP);

      assert.equal(result.summary.invalid, 1);
      assert.ok(result.invalidLines[0].errors[0].includes('Non-Medika article code'));
    });

    it('should reject missing article code', () => {
      const result = runValidator([
        { quantity: 5, pharmacyId: '7700000821' },
      ], VALID_LOOKUP);

      assert.equal(result.summary.invalid, 1);
      assert.ok(result.invalidLines[0].errors[0].includes('Missing article ID'));
    });
  });

  describe('pharmacy ID validation', () => {

    it('should resolve known pharmacy ID', () => {
      const result = runValidator([
        { drugCode: '300103827', quantity: 2, pharmacyId: '7700000821' },
      ], VALID_LOOKUP);

      assert.equal(result.validatedLines[0].customer, 'C001');
      assert.equal(result.validatedLines[0].deliveryPlace, '7700000821');
    });

    it('should error on missing pharmacy ID', () => {
      const result = runValidator([
        { drugCode: '300103827', quantity: 2 },
      ]);

      assert.equal(result.summary.invalid, 1);
      assert.ok(result.invalidLines[0].errors.some(e => e.includes('Cannot determine Customer ID')));
    });

    it('should error on unknown pharmacy ID', () => {
      const result = runValidator([
        { drugCode: '300103827', quantity: 2, pharmacyId: '9999999999' },
      ]);

      assert.equal(result.summary.invalid, 1);
      assert.ok(result.invalidLines[0].errors.some(e => e.includes('Cannot determine Customer ID')));
    });
  });

  describe('quantity validation', () => {

    it('should reject zero quantity', () => {
      const result = runValidator([
        { drugCode: '300103827', quantity: 0, pharmacyId: '7700000821' },
      ], VALID_LOOKUP);

      assert.equal(result.summary.invalid, 1);
      assert.ok(result.invalidLines[0].errors.some(e => e.includes('quantity')));
    });

    it('should reject negative quantity', () => {
      const result = runValidator([
        { drugCode: '300103827', quantity: -5, pharmacyId: '7700000821' },
      ], VALID_LOOKUP);

      assert.equal(result.summary.invalid, 1);
    });
  });
});
