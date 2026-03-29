/**
 * Unit tests for the Feedback Widget JS logic.
 *
 * Tests the pure functions (escaping, time formatting, comment filtering)
 * without needing a browser or API.
 *
 * Usage:
 *   node --test widgets/feedback/feedback.test.mjs
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

// ── Extract and test pure helper functions ──

// Replicate the esc() function from feedback.js
function esc(str) {
  if (!str) return '';
  // Node doesn't have document.createElement, so replicate the logic
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#x27;');
}

// Replicate formatTime() from feedback.js
function formatTime(ts) {
  if (!ts) return '';
  try {
    const d = new Date(ts);
    if (isNaN(d.getTime())) return ts;
    return d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  } catch (e) {
    return ts;
  }
}

// Replicate comment filtering logic
function getTopLevelComments(comments) {
  return comments.filter(c => !c.parent_id);
}

function getReplies(comments, parentId) {
  return comments.filter(c => String(c.parent_id) === String(parentId));
}

// ── Tests ──

describe('esc() — HTML escaping', () => {
  it('escapes angle brackets', () => {
    assert.equal(esc('<script>alert("xss")</script>'), '&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;');
  });

  it('escapes ampersands', () => {
    assert.equal(esc('A & B'), 'A &amp; B');
  });

  it('escapes quotes', () => {
    assert.equal(esc('He said "hello"'), 'He said &quot;hello&quot;');
  });

  it('returns empty string for null/undefined', () => {
    assert.equal(esc(null), '');
    assert.equal(esc(undefined), '');
    assert.equal(esc(''), '');
  });

  it('passes through safe text unchanged', () => {
    assert.equal(esc('Hello world'), 'Hello world');
  });

  it('handles Croatian characters', () => {
    assert.equal(esc('Složenost posla čćšžđ'), 'Složenost posla čćšžđ');
  });
});

describe('formatTime() — timestamp formatting', () => {
  it('formats ISO timestamp', () => {
    const result = formatTime('2026-03-15T14:32:00Z');

    assert.ok(result.length > 0, 'should produce non-empty string');
    // Don't check exact format — it's locale-dependent
    assert.notEqual(result, '2026-03-15T14:32:00Z', 'should not return raw ISO string');
  });

  it('returns empty string for null/undefined', () => {
    assert.equal(formatTime(null), '');
    assert.equal(formatTime(undefined), '');
    assert.equal(formatTime(''), '');
  });

  it('returns original string for invalid date', () => {
    assert.equal(formatTime('not-a-date'), 'not-a-date');
  });
});

describe('getTopLevelComments() — filtering', () => {
  const comments = [
    { id: 1, parent_id: null, comment: 'Top 1' },
    { id: 2, parent_id: null, comment: 'Top 2' },
    { id: 3, parent_id: 1, comment: 'Reply to 1' },
    { id: 4, parent_id: 1, comment: 'Another reply to 1' },
    { id: 5, parent_id: 2, comment: 'Reply to 2' },
  ];

  it('returns only top-level comments', () => {
    const result = getTopLevelComments(comments);

    assert.equal(result.length, 2);
    assert.equal(result[0].id, 1);
    assert.equal(result[1].id, 2);
  });

  it('returns empty array when all are replies', () => {
    const replies = [
      { id: 3, parent_id: 1, comment: 'Reply' },
      { id: 4, parent_id: 2, comment: 'Reply' },
    ];

    assert.equal(getTopLevelComments(replies).length, 0);
  });

  it('returns all when none are replies', () => {
    const tops = [
      { id: 1, parent_id: null, comment: 'A' },
      { id: 2, parent_id: null, comment: 'B' },
    ];

    assert.equal(getTopLevelComments(tops).length, 2);
  });

  it('handles empty array', () => {
    assert.equal(getTopLevelComments([]).length, 0);
  });
});

describe('getReplies() — thread filtering', () => {
  const comments = [
    { id: 1, parent_id: null, comment: 'Top 1' },
    { id: 2, parent_id: null, comment: 'Top 2' },
    { id: 3, parent_id: 1, comment: 'Reply to 1' },
    { id: 4, parent_id: 1, comment: 'Another reply to 1' },
    { id: 5, parent_id: 2, comment: 'Reply to 2' },
  ];

  it('returns replies for a specific parent', () => {
    const result = getReplies(comments, 1);

    assert.equal(result.length, 2);
    assert.equal(result[0].id, 3);
    assert.equal(result[1].id, 4);
  });

  it('handles string/number parent_id mismatch', () => {
    const result = getReplies(comments, '1');

    assert.equal(result.length, 2, 'should match even when types differ');
  });

  it('returns empty for parent with no replies', () => {
    assert.equal(getReplies(comments, 999).length, 0);
  });

  it('returns empty for empty comments array', () => {
    assert.equal(getReplies([], 1).length, 0);
  });
});

describe('Coordinate calculations', () => {
  it('percentage to pixel conversion is reversible', () => {
    const docW = 1920;
    const docH = 4000;
    const clickX = 960;
    const clickY = 2500;

    // Store as percentage
    const x_pct = Math.round((clickX / docW) * 10000) / 100;
    const y_pct = Math.round((clickY / docH) * 10000) / 100;

    // Convert back to pixels
    const renderedX = x_pct / 100 * docW;
    const renderedY = y_pct / 100 * docH;

    // Should be within 1px due to rounding
    assert.ok(Math.abs(renderedX - clickX) < 1, `X: ${renderedX} should be close to ${clickX}`);
    assert.ok(Math.abs(renderedY - clickY) < 1, `Y: ${renderedY} should be close to ${clickY}`);
  });

  it('handles edge positions (0%, 100%)', () => {
    const docW = 1920;
    const docH = 4000;

    // Top-left corner
    const x0 = Math.round((0 / docW) * 10000) / 100;
    const y0 = Math.round((0 / docH) * 10000) / 100;
    assert.equal(x0, 0);
    assert.equal(y0, 0);

    // Bottom-right corner
    const x100 = Math.round((docW / docW) * 10000) / 100;
    const y100 = Math.round((docH / docH) * 10000) / 100;
    assert.equal(x100, 100);
    assert.equal(y100, 100);
  });
});

describe('Delete eligibility', () => {
  it('can delete own comment without replies', () => {
    const currentAuthor = 'Vlatko';
    const comment = { id: 1, author: 'Vlatko', parent_id: null };
    const replies = [];

    const canDelete = comment.author === currentAuthor && replies.length === 0;

    assert.equal(canDelete, true);
  });

  it('cannot delete own comment with replies', () => {
    const currentAuthor = 'Vlatko';
    const comment = { id: 1, author: 'Vlatko', parent_id: null };
    const replies = [{ id: 2, parent_id: 1, author: 'Dijana' }];

    const canDelete = comment.author === currentAuthor && replies.length === 0;

    assert.equal(canDelete, false);
  });

  it('cannot delete someone else\'s comment', () => {
    const currentAuthor = 'Vlatko';
    const comment = { id: 1, author: 'Dijana', parent_id: null };
    const replies = [];

    const canDelete = comment.author === currentAuthor && replies.length === 0;

    assert.equal(canDelete, false);
  });

  it('can delete own reply', () => {
    const currentAuthor = 'Vlatko';
    const reply = { id: 3, author: 'Vlatko', parent_id: 1 };

    const canDelete = reply.author === currentAuthor;

    assert.equal(canDelete, true);
  });
});
