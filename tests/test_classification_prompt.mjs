/**
 * Tests for WF-01b — AI classification prompt content.
 *
 * Verifies the prompt includes patterns for detecting non-orders
 * (internal replies, HR announcements, etc.)
 * Run with: node --test tests/test_classification_prompt.mjs
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');
const WF_PATH = resolve(ROOT, 'workflows/medika-preorders/test/01b_process_email.json');

function loadClassificationPrompt() {
  const wf = JSON.parse(readFileSync(WF_PATH, 'utf8'));
  const node = wf.nodes.find(n => n.name === 'AI: Classify Email');
  if (!node) throw new Error('Node "AI: Classify Email" not found');
  const systemMsg = node.parameters.responses.values.find(v => v.role === 'system');
  if (!systemMsg) throw new Error('System prompt not found');
  return systemMsg.content;
}

describe('AI Classification Prompt', () => {

  const prompt = loadClassificationPrompt();

  describe('internal reply detection', () => {

    it('should mention internal staff replies from @medika.hr', () => {
      assert.ok(prompt.includes('@medika.hr'));
    });

    it('should list "Ispisano" as a handled-confirmation keyword', () => {
      assert.ok(prompt.includes('Ispisano'));
    });

    it('should list "Napravljeno" as a handled-confirmation keyword', () => {
      assert.ok(prompt.includes('Napravljeno'));
    });

    it('should list "Riješeno" as a handled-confirmation keyword', () => {
      assert.ok(prompt.includes('Riješeno'));
    });
  });

  describe('non-order detection', () => {

    it('should mention HR announcements', () => {
      assert.ok(prompt.includes('Novi član'));
    });

    it('should detect complaints about undelivered items', () => {
      assert.ok(prompt.includes('neisporučeni'));
    });

    it('should detect forwarded correspondence', () => {
      assert.ok(prompt.toLowerCase().includes('forwarded'));
    });
  });

  describe('order detection', () => {

    it('should mention Croatian ordering keywords', () => {
      assert.ok(prompt.includes('prednarudžba'));
      assert.ok(prompt.includes('narudžba'));
    });

    it('should return JSON format specification', () => {
      assert.ok(prompt.includes('isOrder'));
      assert.ok(prompt.includes('reason'));
    });
  });
});
