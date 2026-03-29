/* ============================================
   Visual Feedback Widget
   Drop-in script for any website. Click to pin
   comments, view threads, reply inline.

   Usage:
     <script src="feedback.js"
             data-api="https://your-n8n/webhook/comments"
             data-token="your-token"
             data-project="my-project">
     </script>

   All three data attributes are required.
   Comments are scoped by project + page.
   ============================================ */
(function() {
  // ── Config from script tag ──
  const scriptTag = document.currentScript;
  const API = scriptTag?.getAttribute('data-api');
  const TOKEN = scriptTag?.getAttribute('data-token');
  const PROJECT = scriptTag?.getAttribute('data-project');

  if (!API || !TOKEN || !PROJECT) {
    console.error('Feedback widget: missing data-api, data-token, or data-project attributes');
    return;
  }

  const PAGE = location.pathname.split('/').pop() || 'index.html';
  const AUTHOR_KEY = 'feedback_author';

  let feedbackMode = false;
  let comments = [];
  let pins = [];

  // ── Styles ──
  const style = document.createElement('style');
  style.textContent = `
    .fb-toggle {
      position: fixed; bottom: 24px; right: 24px; z-index: 10000;
      width: 52px; height: 52px; border-radius: 50%;
      background: #3730a3; color: #fff; border: none; cursor: pointer;
      font-size: 22px; display: flex; align-items: center; justify-content: center;
      box-shadow: 0 4px 16px rgba(55,48,163,0.35);
      transition: all 0.2s;
    }
    .fb-toggle:hover { transform: scale(1.08); box-shadow: 0 6px 24px rgba(55,48,163,0.45); }
    .fb-toggle.active { background: #ef4444; }
    .fb-toggle .fb-count {
      position: absolute; top: -4px; right: -4px;
      background: #f59e0b; color: #1f2937; font-size: 11px; font-weight: 800;
      width: 20px; height: 20px; border-radius: 50%;
      display: flex; align-items: center; justify-content: center;
    }

    .fb-banner {
      position: fixed; bottom: 84px; right: 24px; z-index: 10000;
      background: #1e1b4b; color: #e0e7ff; padding: 8px 16px;
      border-radius: 8px; font-size: 13px; font-family: Inter, sans-serif;
      box-shadow: 0 4px 12px rgba(0,0,0,0.2);
      opacity: 0; transition: opacity 0.2s; pointer-events: none;
    }
    .fb-banner.show { opacity: 1; }

    .fb-pin {
      position: absolute; z-index: 9998; cursor: pointer;
      width: 28px; height: 28px; border-radius: 50%;
      background: #3730a3; color: #fff; border: 2px solid #fff;
      font-size: 11px; font-weight: 800;
      display: flex; align-items: center; justify-content: center;
      box-shadow: 0 2px 8px rgba(0,0,0,0.25);
      transform: translate(-50%, -50%);
      transition: transform 0.15s;
    }
    .fb-pin:hover { transform: translate(-50%, -50%) scale(1.15); }
    .fb-pin.resolved { background: #9ca3af; border-color: #e5e7eb; }

    .fb-popup {
      position: absolute; z-index: 9999;
      background: #fff; border-radius: 12px;
      box-shadow: 0 8px 32px rgba(0,0,0,0.18);
      border: 1px solid #e5e7eb;
      width: 320px; max-height: 420px;
      font-family: Inter, -apple-system, sans-serif;
      overflow: hidden; display: flex; flex-direction: column;
    }

    .fb-popup-header {
      padding: 12px 16px; border-bottom: 1px solid #f3f4f6;
      display: flex; align-items: center; justify-content: space-between;
      background: #f9fafb;
    }
    .fb-popup-header span { font-size: 12px; font-weight: 700; color: #374151; }
    .fb-popup-close {
      width: 24px; height: 24px; border-radius: 6px;
      border: none; background: #f3f4f6; cursor: pointer;
      font-size: 14px; color: #6b7280; display: flex;
      align-items: center; justify-content: center;
    }
    .fb-popup-close:hover { background: #fee2e2; color: #ef4444; }

    .fb-popup-body {
      padding: 12px 16px; overflow-y: auto; flex: 1;
    }

    .fb-comment {
      margin-bottom: 12px; padding-bottom: 12px;
      border-bottom: 1px solid #f3f4f6;
    }
    .fb-comment:last-child { border-bottom: none; margin-bottom: 0; padding-bottom: 0; }
    .fb-comment-author {
      font-size: 12px; font-weight: 700; color: #3730a3;
    }
    .fb-comment-time {
      font-size: 10px; color: #9ca3af; margin-left: 8px;
    }
    .fb-comment-text {
      font-size: 13px; color: #374151; margin-top: 4px; line-height: 1.5;
    }
    .fb-reply { margin-left: 16px; padding-left: 12px; border-left: 2px solid #e5e7eb; }

    .fb-form { padding: 12px 16px; border-top: 1px solid #f3f4f6; background: #f9fafb; }
    .fb-input {
      width: 100%; padding: 8px 10px; border: 1px solid #d1d5db;
      border-radius: 8px; font-size: 13px; font-family: Inter, sans-serif;
      resize: vertical; min-height: 60px; outline: none;
      transition: border-color 0.15s;
    }
    .fb-input:focus { border-color: #3730a3; }
    .fb-author-input {
      width: 100%; padding: 6px 10px; border: 1px solid #d1d5db;
      border-radius: 6px; font-size: 12px; font-family: Inter, sans-serif;
      margin-bottom: 8px; outline: none;
    }
    .fb-author-input:focus { border-color: #3730a3; }
    .fb-submit-row { display: flex; gap: 8px; margin-top: 8px; align-items: center; }
    .fb-submit {
      padding: 6px 14px; border-radius: 6px; border: none;
      background: #3730a3; color: #fff; font-size: 12px; font-weight: 600;
      cursor: pointer; font-family: Inter, sans-serif;
    }
    .fb-submit:hover { background: #4f46e5; }
    .fb-submit:disabled { opacity: 0.5; cursor: not-allowed; }
    .fb-cancel {
      padding: 6px 14px; border-radius: 6px; border: 1px solid #d1d5db;
      background: #fff; color: #6b7280; font-size: 12px; font-weight: 500;
      cursor: pointer; font-family: Inter, sans-serif;
    }
    .fb-cancel:hover { background: #f3f4f6; }
    .fb-resolve {
      margin-left: auto; padding: 4px 10px; border-radius: 6px;
      border: 1px solid #d1d5db; background: #fff; color: #6b7280;
      font-size: 11px; cursor: pointer; font-family: Inter, sans-serif;
    }
    .fb-resolve:hover { background: #d1fae5; color: #065f46; border-color: #10b981; }

    .fb-delete {
      border: none; background: none; cursor: pointer;
      font-size: 14px; opacity: 0.4; padding: 2px 4px; border-radius: 4px;
      transition: all 0.15s;
    }
    .fb-delete:hover { opacity: 1; background: #fee2e2; }

    body { position: relative; }
    body.fb-mode { cursor: crosshair !important; }
    body.fb-mode * { cursor: crosshair !important; }
    body.fb-mode .fb-toggle,
    body.fb-mode .fb-pin,
    body.fb-mode .fb-popup,
    body.fb-mode .fb-popup * { cursor: default !important; }
  `;
  document.head.appendChild(style);

  // ── Toggle Button ──
  const toggle = document.createElement('button');
  toggle.className = 'fb-toggle';
  toggle.innerHTML = '&#128172;';
  toggle.title = 'Feedback mode';
  document.body.appendChild(toggle);

  const banner = document.createElement('div');
  banner.className = 'fb-banner';
  banner.textContent = 'Click anywhere on the page to leave a comment';
  document.body.appendChild(banner);

  toggle.addEventListener('click', (e) => {
    e.stopPropagation();
    feedbackMode = !feedbackMode;
    toggle.classList.toggle('active', feedbackMode);
    document.body.classList.toggle('fb-mode', feedbackMode);
    banner.classList.toggle('show', feedbackMode);
    closeAllPopups();
  });

  // ── API Calls ──
  async function fetchComments() {
    try {
      const res = await fetch(API + '?project=' + encodeURIComponent(PROJECT) + '&page=' + encodeURIComponent(PAGE), {
        headers: { 'X-Feedback-Token': TOKEN }
      });
      if (!res.ok) return [];
      const data = await res.json();
      return Array.isArray(data) ? data : [];
    } catch(e) {
      console.error('Feedback: fetch error', e);
      return [];
    }
  }

  async function postComment(data) {
    try {
      const res = await fetch(API, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Feedback-Token': TOKEN
        },
        body: JSON.stringify({
          project: PROJECT,
          page: PAGE,
          x_pct: data.x_pct,
          y_pct: data.y_pct,
          comment: data.comment,
          author: data.author,
          parent_id: data.parent_id || null
        })
      });
      return res.ok;
    } catch(e) {
      console.error('Feedback: post error', e);
      return false;
    }
  }

  async function deleteComment(id) {
    try {
      const res = await fetch(API + '?id=' + encodeURIComponent(id), {
        method: 'DELETE',
        headers: { 'X-Feedback-Token': TOKEN }
      });
      if (!res.ok) {
        const data = await res.json().catch(() => ({}));
        if (data.error) alert(data.error);
        return false;
      }
      return true;
    } catch(e) {
      console.error('Feedback: delete error', e);
      return false;
    }
  }

  // ── Render Pins ──
  function clearPins() {
    pins.forEach(p => p.remove());
    pins = [];
  }

  function closeAllPopups() {
    document.querySelectorAll('.fb-popup').forEach(p => p.remove());
  }

  function getTopLevelComments() {
    return comments.filter(c => !c.parent_id);
  }

  function getReplies(parentId) {
    return comments.filter(c => String(c.parent_id) === String(parentId));
  }

  function renderPins() {
    clearPins();
    const topLevel = getTopLevelComments();

    const existing = toggle.querySelector('.fb-count');
    if (existing) existing.remove();
    if (topLevel.length > 0) {
      const badge = document.createElement('span');
      badge.className = 'fb-count';
      badge.textContent = topLevel.length;
      toggle.appendChild(badge);
    }

    topLevel.forEach((c, i) => {
      const pin = document.createElement('div');
      pin.className = 'fb-pin' + (c.resolved ? ' resolved' : '');
      pin.textContent = i + 1;
      const docW = Math.max(document.body.scrollWidth, document.documentElement.scrollWidth);
      const docH = Math.max(document.body.scrollHeight, document.documentElement.scrollHeight);
      pin.style.left = (c.x_pct / 100 * docW) + 'px';
      pin.style.top = (c.y_pct / 100 * docH) + 'px';
      pin.addEventListener('click', (e) => {
        e.stopPropagation();
        closeAllPopups();
        showThread(c, pin);
      });
      document.body.appendChild(pin);
      pins.push(pin);
    });
  }

  // ── Thread Popup ──
  function showThread(comment, pinEl) {
    closeAllPopups();
    const popup = document.createElement('div');
    popup.className = 'fb-popup';

    const rect = pinEl.getBoundingClientRect();
    const scrollX = window.scrollX;
    const scrollY = window.scrollY;
    let left = rect.right + scrollX + 8;
    let top = rect.top + scrollY - 20;

    if (left + 330 > document.documentElement.scrollWidth) {
      left = rect.left + scrollX - 330;
    }
    popup.style.left = left + 'px';
    popup.style.top = top + 'px';

    const replies = getReplies(comment.id);

    const currentAuthor = localStorage.getItem(AUTHOR_KEY) || '';
    const canDeleteTop = comment.author === currentAuthor && replies.length === 0;

    popup.innerHTML = `
      <div class="fb-popup-header">
        <span>Comment #${Array.from(document.querySelectorAll('.fb-pin')).indexOf(pinEl) + 1}</span>
        <div style="display:flex;gap:4px;">
          <button class="fb-popup-close">&times;</button>
        </div>
      </div>
      <div class="fb-popup-body">
        <div class="fb-comment">
          <div style="display:flex;align-items:center;justify-content:space-between;">
            <div>
              <span class="fb-comment-author">${esc(comment.author)}</span>
              <span class="fb-comment-time">${formatTime(comment.created_at)}</span>
            </div>
            ${canDeleteTop ? `<button class="fb-delete" data-id="${comment.id}" title="Delete">&#128465;</button>` : ''}
          </div>
          <div class="fb-comment-text">${esc(comment.comment)}</div>
        </div>
        ${replies.map(r => `
          <div class="fb-comment fb-reply">
            <div style="display:flex;align-items:center;justify-content:space-between;">
              <div>
                <span class="fb-comment-author">${esc(r.author)}</span>
                <span class="fb-comment-time">${formatTime(r.created_at)}</span>
              </div>
              ${r.author === currentAuthor ? `<button class="fb-delete" data-id="${r.id}" title="Delete">&#128465;</button>` : ''}
            </div>
            <div class="fb-comment-text">${esc(r.comment)}</div>
          </div>
        `).join('')}
      </div>
      <div class="fb-form">
        <textarea class="fb-input" placeholder="Reply..."></textarea>
        <div class="fb-submit-row">
          <button class="fb-submit">Reply</button>
        </div>
      </div>
    `;

    document.body.appendChild(popup);

    popup.querySelector('.fb-popup-close').addEventListener('click', () => popup.remove());

    popup.querySelectorAll('.fb-delete').forEach(btn => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        if (!confirm('Delete this comment?')) return;
        const id = btn.getAttribute('data-id');
        const ok = await deleteComment(id);
        if (ok) {
          popup.remove();
          await refreshComments();
        }
      });
    });

    popup.querySelector('.fb-submit').addEventListener('click', async () => {
      const text = popup.querySelector('.fb-input').value.trim();
      if (!text) return;
      const author = getAuthor();
      if (!author) return;
      const btn = popup.querySelector('.fb-submit');
      btn.disabled = true;
      btn.textContent = '...';
      const ok = await postComment({
        x_pct: comment.x_pct,
        y_pct: comment.y_pct,
        comment: text,
        author: author,
        parent_id: comment.id
      });
      if (ok) {
        await refreshComments();
        const updated = comments.find(c => String(c.id) === String(comment.id));
        if (updated) {
          const newPin = pins.find(p =>
            p.style.left === updated.x_pct + '%' && p.style.top === updated.y_pct + '%'
          );
          if (newPin) showThread(updated, newPin);
        }
      }
      btn.disabled = false;
      btn.textContent = 'Reply';
    });
  }

  // ── New Comment Popup ──
  function showNewCommentForm(x_pct, y_pct) {
    closeAllPopups();
    const popup = document.createElement('div');
    popup.className = 'fb-popup';

    const scrollX = window.scrollX;
    const scrollY = window.scrollY;
    const ndocW = Math.max(document.body.scrollWidth, document.documentElement.scrollWidth);
    const ndocH = Math.max(document.body.scrollHeight, document.documentElement.scrollHeight);
    let left = (x_pct / 100) * ndocW + 16;
    let top = (y_pct / 100) * ndocH - 20;
    if (left + 330 > ndocW) {
      left = left - 350;
    }
    popup.style.left = left + 'px';
    popup.style.top = top + 'px';

    const savedAuthor = localStorage.getItem(AUTHOR_KEY) || '';

    popup.innerHTML = `
      <div class="fb-popup-header">
        <span>New comment</span>
        <button class="fb-popup-close">&times;</button>
      </div>
      <div class="fb-form" style="border-top: none;">
        <input class="fb-author-input" placeholder="Your name" value="${esc(savedAuthor)}" />
        <textarea class="fb-input" placeholder="Write a comment..." autofocus></textarea>
        <div class="fb-submit-row">
          <button class="fb-submit">Save</button>
          <button class="fb-cancel">Cancel</button>
        </div>
      </div>
    `;

    document.body.appendChild(popup);
    popup.querySelector('.fb-input').focus();

    popup.querySelector('.fb-popup-close').addEventListener('click', () => popup.remove());
    popup.querySelector('.fb-cancel').addEventListener('click', () => popup.remove());

    popup.querySelector('.fb-submit').addEventListener('click', async () => {
      const text = popup.querySelector('.fb-input').value.trim();
      const author = popup.querySelector('.fb-author-input').value.trim();
      if (!text || !author) return;
      localStorage.setItem(AUTHOR_KEY, author);
      const btn = popup.querySelector('.fb-submit');
      btn.disabled = true;
      btn.textContent = '...';
      const ok = await postComment({ x_pct, y_pct, comment: text, author, parent_id: null });
      if (ok) {
        popup.remove();
        feedbackMode = false;
        toggle.classList.remove('active');
        document.body.classList.remove('fb-mode');
        banner.classList.remove('show');
        await refreshComments();
      }
      btn.disabled = false;
      btn.textContent = 'Save';
    });
  }

  // ── Close popups on outside click (always active) ──
  document.addEventListener('mousedown', (e) => {
    if (!e.target.closest('.fb-popup, .fb-pin, .fb-toggle')) {
      closeAllPopups();
    }
  });

  // ── Click Handler (feedback mode only) ──
  document.addEventListener('click', (e) => {
    if (!feedbackMode) return;
    if (e.target.closest('.fb-toggle, .fb-pin, .fb-popup, .fb-banner')) return;

    const docW = Math.max(document.body.scrollWidth, document.documentElement.scrollWidth);
    const docH = Math.max(document.body.scrollHeight, document.documentElement.scrollHeight);
    const x_pct = Math.round((e.pageX / docW) * 10000) / 100;
    const y_pct = Math.round((e.pageY / docH) * 10000) / 100;

    showNewCommentForm(x_pct, y_pct);

    feedbackMode = false;
    toggle.classList.remove('active');
    document.body.classList.remove('fb-mode');
    banner.classList.remove('show');
  });

  // ── Helpers ──
  function getAuthor() {
    const a = localStorage.getItem(AUTHOR_KEY);
    if (a) return a;
    const name = prompt('Your name:');
    if (name) localStorage.setItem(AUTHOR_KEY, name);
    return name;
  }

  function esc(str) {
    if (!str) return '';
    const d = document.createElement('div');
    d.textContent = str;
    return d.innerHTML;
  }

  function formatTime(ts) {
    if (!ts) return '';
    try {
      const d = new Date(ts);
      return d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    } catch(e) {
      return ts;
    }
  }

  async function refreshComments() {
    comments = await fetchComments();
    renderPins();
  }

  // ── Init ──
  refreshComments();
})();
