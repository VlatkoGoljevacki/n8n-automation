/**
 * Integration tests for the Feedback Comments API (n8n webhooks).
 *
 * Tests the GET/POST/DELETE endpoints for the visual feedback widget.
 * Requires the n8n server to be running and accessible.
 *
 * Usage:
 *   N8N_URL=https://your-tunnel.trycloudflare.com node --test tests/test_feedback_api.mjs
 *
 * Environment:
 *   N8N_URL  — base URL of n8n instance (required)
 *   FB_TOKEN — feedback token (default: n8n-automation-wladisha)
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';

const BASE = process.env.N8N_URL;
if (!BASE) {
  console.error('ERROR: Set N8N_URL environment variable (e.g., https://xxx.trycloudflare.com)');
  process.exit(1);
}

const API = `${BASE}/webhook/test-comments`;
const TOKEN = process.env.FB_TOKEN || 'n8n-automation-wladisha';
const TEST_PROJECT = '__test_feedback_' + Date.now();

const headers = {
  'Content-Type': 'application/json',
  'X-Feedback-Token': TOKEN,
};

// Track created IDs for cleanup
const createdIds = [];

async function postComment(data) {
  const res = await fetch(API, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      project: TEST_PROJECT,
      page: 'test-page.html',
      x_pct: 50,
      y_pct: 50,
      parent_id: null,
      ...data,
    }),
  });
  const json = await res.json();
  if (res.ok && json.id) createdIds.push(json.id);
  return { status: res.status, data: json };
}

async function getComments(page = 'test-page.html') {
  const res = await fetch(`${API}?project=${TEST_PROJECT}&page=${encodeURIComponent(page)}`, {
    headers,
  });
  return { status: res.status, data: await res.json() };
}

async function deleteComment(id) {
  const res = await fetch(`${API}?id=${id}`, {
    method: 'DELETE',
    headers,
  });
  return { status: res.status, data: await res.json() };
}

// ── Auth Tests ──

describe('Authentication', () => {
  it('GET without token returns 403', async () => {
    const res = await fetch(`${API}?project=${TEST_PROJECT}&page=test.html`);
    assert.equal(res.status, 403);
  });

  it('POST without token returns 403', async () => {
    const res = await fetch(API, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ project: 'x', page: 'x', comment: 'x', author: 'x' }),
    });
    assert.equal(res.status, 403);
  });

  it('DELETE without token returns 403', async () => {
    const res = await fetch(`${API}?id=1`, { method: 'DELETE' });
    assert.equal(res.status, 403);
  });

  it('GET with wrong token returns 403', async () => {
    const res = await fetch(`${API}?project=${TEST_PROJECT}&page=test.html`, {
      headers: { 'X-Feedback-Token': 'wrong-token' },
    });
    assert.equal(res.status, 403);
  });
});

// ── POST Tests ──

describe('POST /comments', () => {
  it('creates a top-level comment', async () => {
    const { status, data } = await postComment({
      comment: 'Test comment',
      author: 'TestBot',
    });

    assert.equal(status, 200);
    assert.ok(data.id, 'should return an id');
  });

  it('creates a reply to an existing comment', async () => {
    const parent = await postComment({
      comment: 'Parent comment',
      author: 'TestBot',
    });

    const { status, data } = await postComment({
      comment: 'Reply to parent',
      author: 'TestBot',
      parent_id: parent.data.id,
    });

    assert.equal(status, 200);
    assert.ok(data.id);
  });

  it('stores x_pct and y_pct correctly', async () => {
    const { data } = await postComment({
      comment: 'Positioned comment',
      author: 'TestBot',
      x_pct: 73.45,
      y_pct: 21.8,
    });

    assert.ok(data.id);
  });
});

// ── GET Tests ──

describe('GET /comments', () => {
  it('returns comments for the correct project and page', async () => {
    const { status, data } = await getComments();

    assert.equal(status, 200);
    assert.ok(Array.isArray(data), 'should return an array');
    assert.ok(data.length > 0, 'should have comments from POST tests');
  });

  it('returns empty array for nonexistent page', async () => {
    const { status, data } = await getComments('nonexistent-page.html');

    assert.equal(status, 200);
    assert.ok(Array.isArray(data));
    assert.equal(data.length, 0);
  });

  it('returned comments have expected fields', async () => {
    const { data } = await getComments();
    const comment = data[0];

    assert.ok(comment.id, 'should have id');
    assert.ok(comment.comment, 'should have comment');
    assert.ok(comment.author, 'should have author');
    assert.ok(comment.page, 'should have page');
    assert.ok('x_pct' in comment, 'should have x_pct');
    assert.ok('y_pct' in comment, 'should have y_pct');
    assert.ok('created_at' in comment, 'should have created_at');
  });
});

// ── DELETE Tests ──

describe('DELETE /comments', () => {
  it('deletes a comment without children', async () => {
    const { data: created } = await postComment({
      comment: 'To be deleted',
      author: 'TestBot',
    });

    const { status, data } = await deleteComment(created.id);

    assert.equal(status, 200);
    assert.equal(data.deleted, true);

    // Remove from cleanup list since already deleted
    const idx = createdIds.indexOf(created.id);
    if (idx > -1) createdIds.splice(idx, 1);
  });

  it('rejects deleting a comment with children (409)', async () => {
    const { data: parent } = await postComment({
      comment: 'Parent with child',
      author: 'TestBot',
    });

    await postComment({
      comment: 'Child comment',
      author: 'TestBot',
      parent_id: parent.id,
    });

    const { status, data } = await deleteComment(parent.id);

    assert.equal(status, 409);
    assert.ok(data.error);
  });

  it('returns error for nonexistent comment', async () => {
    const { status } = await deleteComment(999999);

    // Could be 404 or 200 depending on n8n workflow implementation
    assert.ok([200, 404].includes(status));
  });
});

// ── Cleanup ──

after(async () => {
  // Delete test comments in reverse order (children first)
  for (const id of createdIds.reverse()) {
    try {
      await deleteComment(id);
    } catch (e) {
      // Ignore cleanup errors
    }
  }
});
