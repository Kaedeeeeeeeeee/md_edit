// Notation landing page — vanilla JS, no deps.

document.addEventListener('DOMContentLoaded', () => {
  initNavScroll();
  initFAQ();
  initFooterYear();
  initHeroAnimation();
});

// ---------------------------------------------------------------------------
// Nav scroll-shadow: add .scrolled class once user has scrolled past 8px.
// ---------------------------------------------------------------------------
function initNavScroll() {
  const nav = document.querySelector('.nav');
  if (!nav) return;
  const onScroll = () => nav.classList.toggle('scrolled', window.scrollY > 8);
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();
}

// ---------------------------------------------------------------------------
// FAQ accordion: only one item open at a time. First item open by default.
// ---------------------------------------------------------------------------
function initFAQ() {
  const items = document.querySelectorAll('.faq-item');
  items.forEach((item) => {
    const btn = item.querySelector('.faq-q');
    if (!btn) return;
    btn.addEventListener('click', () => {
      const isOpen = item.classList.contains('open');
      items.forEach((other) => other.classList.remove('open'));
      if (!isOpen) item.classList.add('open');
    });
  });
  if (items[0]) items[0].classList.add('open');
}

// ---------------------------------------------------------------------------
// Footer year — auto-updates so the copyright never goes stale.
// ---------------------------------------------------------------------------
function initFooterYear() {
  document.querySelectorAll('[data-year]').forEach((el) => {
    el.textContent = String(new Date().getFullYear());
  });
}

// ---------------------------------------------------------------------------
// Hero typing animation
//
// One self-playing animation that cycles through three content "styles" —
// office, technical, fiction — to signal Notation's audience range, while
// punctuating each cycle with two block-editing feature demonstrations:
//   - a slash menu pop-up showing block insertion
//   - a + drag handle briefly appearing beside the just-typed block
// ---------------------------------------------------------------------------

const TYPING_CYCLES = [
  {
    title: '周一站会.md',
    badge: '会议笔记',
    blocks: [
      { type: 'h1', text: '周一站会' },
      { type: 'p',  text: '本周目标：完成 Notation 1.0 提审。' },
      { type: 'h2', text: '本周待办', slashIntro: 'h2' },
      { type: 'ul', text: '准备 App Store 截图与文案' },
      { type: 'ul', text: '联系 50 位种子用户' },
    ],
  },
  {
    title: '部署 v1.0.md',
    badge: '技术笔记',
    blocks: [
      { type: 'h1', text: '部署 v1.0' },
      { type: 'ul', text: '所有单元测试通过' },
      { type: 'ul', text: '合并 release/v1.0 分支' },
      { type: 'code', text: 'xcodebuild -scheme Notation archive', slashIntro: 'code' },
    ],
  },
  {
    title: '第一章.md',
    badge: '小说',
    blocks: [
      { type: 'h1', text: '第一章' },
      { type: 'p',  text: '凌晨三点，手机在枕边震了三下停了。' },
      { type: 'p',  text: '屏幕上是一条陌生人消息——没有备注，没有头像。' },
      { type: 'quote', text: '"你还有七天的命。"', slashIntro: 'quote' },
    ],
  },
];

// Items the slash menu always shows — order matters. The block following the
// `/` press is shown highlighted so the visual reads as "you press /, the
// menu opens, the right block is selected."
const SLASH_ITEMS = [
  { key: 'h1',    label: '标题 1',    token: 'H1', trigger: '#' },
  { key: 'h2',    label: '标题 2',    token: 'H2', trigger: '##' },
  { key: 'ul',    label: '无序列表', token: '•',  trigger: '-' },
  { key: 'quote', label: '引用',      token: '"',  trigger: '>' },
  { key: 'code',  label: '代码块',    token: '</>', trigger: '```' },
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function initHeroAnimation() {
  const root = document.querySelector('[data-typing-root]');
  if (!root) return;
  runTypingLoop(root);
}

async function runTypingLoop(root) {
  // Infinite loop; we run as long as the page is mounted. The page doesn't
  // unmount during normal use, so we don't bother with abort plumbing.
  while (true) {
    for (const cycle of TYPING_CYCLES) {
      await runCycle(root, cycle);
    }
  }
}

async function runCycle(root, cycle) {
  const titleEl = document.querySelector('[data-typing-title]');
  const badgeEl = document.querySelector('[data-typing-badge]');

  // Reset canvas + window chrome.
  root.classList.remove('fading');
  root.innerHTML = '';
  if (titleEl) titleEl.textContent = cycle.title;
  if (badgeEl) badgeEl.textContent = cycle.badge;

  for (const block of cycle.blocks) {
    if (block.slashIntro) {
      await showSlashMenu(root, block.slashIntro);
    }
    const blockEl = appendBlock(root, block.type);
    await typeIntoBlock(blockEl, block.text);
    await showHandlesBriefly(blockEl, 500);
  }

  // Hold the finished result, then fade out before the next cycle.
  await sleep(1800);
  root.classList.add('fading');
  await sleep(500);
}

// Builds a block DOM node ready to be typed into. Returns the wrapper so the
// caller can pass it to typeIntoBlock / showHandlesBriefly.
function appendBlock(root, type) {
  const wrap = document.createElement('div');
  wrap.className = 'typing-block';

  const handles = document.createElement('div');
  handles.className = 'typing-handles';
  handles.innerHTML = `
    <button aria-label="添加块" tabindex="-1"><svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M6 2 V10 M2 6 H10"/></svg></button>
    <button class="grab" aria-label="拖动重排" tabindex="-1"><svg width="10" height="14" viewBox="0 0 10 14" fill="currentColor"><circle cx="3" cy="3" r="1.2"/><circle cx="7" cy="3" r="1.2"/><circle cx="3" cy="7" r="1.2"/><circle cx="7" cy="7" r="1.2"/><circle cx="3" cy="11" r="1.2"/><circle cx="7" cy="11" r="1.2"/></svg></button>
  `;
  wrap.appendChild(handles);

  let content;
  if (type === 'h1') {
    content = document.createElement('h1');
    content.className = 'tb-h1';
  } else if (type === 'h2') {
    content = document.createElement('h2');
    content.className = 'tb-h2';
  } else if (type === 'ul') {
    content = document.createElement('div');
    content.className = 'tb-ul';
    const bullet = document.createElement('span');
    bullet.className = 'tb-bullet';
    bullet.textContent = '•';
    content.appendChild(bullet);
    const txt = document.createElement('span');
    txt.className = 'tb-ul-text';
    content.appendChild(txt);
  } else if (type === 'quote') {
    content = document.createElement('blockquote');
    content.className = 'tb-quote';
  } else if (type === 'code') {
    content = document.createElement('pre');
    content.className = 'tb-code';
  } else {
    content = document.createElement('p');
    content.className = 'tb-p';
  }
  wrap.appendChild(content);
  root.appendChild(wrap);
  return wrap;
}

// Types `text` one character at a time into the block's content element,
// with a blinking cursor pinned to the end during typing.
async function typeIntoBlock(blockEl, text) {
  const ulText = blockEl.querySelector('.tb-ul-text');
  const target = ulText || blockEl.querySelector('h1, h2, p, blockquote, pre');
  if (!target) return;

  const cursor = document.createElement('span');
  cursor.className = 'type-cursor';
  target.appendChild(cursor);

  for (let i = 0; i < text.length; i++) {
    cursor.before(document.createTextNode(text[i]));
    // Tiny per-char jitter for an organic feel — humans don't type at
    // perfectly even intervals.
    const delay = 38 + Math.random() * 30;
    await sleep(delay);
  }
  cursor.remove();
}

// Shows the + handle on a block for a brief moment, signalling "blocks can
// be reordered / inserted here." Auto-dismisses.
async function showHandlesBriefly(blockEl, duration) {
  const handles = blockEl.querySelector('.typing-handles');
  if (!handles) return;
  handles.classList.add('visible');
  await sleep(duration);
  handles.classList.remove('visible');
  await sleep(180);
}

// Mounts a transient slash-menu DOM node in the typing root, highlights the
// item matching `targetKey`, holds, then dismisses. Used before a block is
// typed to show the user that the block was inserted via the / menu.
async function showSlashMenu(root, targetKey) {
  const menu = document.createElement('div');
  menu.className = 'typing-slash-menu';

  const header = document.createElement('div');
  header.className = 'sm-header';
  header.textContent = '/ 插入块';
  menu.appendChild(header);

  for (const item of SLASH_ITEMS) {
    const row = document.createElement('div');
    row.className = 'sm-item' + (item.key === targetKey ? ' active' : '');

    const icon = document.createElement('span');
    icon.className = 'sm-icon';
    icon.textContent = item.token;
    row.appendChild(icon);

    const label = document.createElement('span');
    label.textContent = item.label;
    row.appendChild(label);

    const trig = document.createElement('span');
    trig.className = 'sm-trigger';
    trig.textContent = item.trigger;
    row.appendChild(trig);

    menu.appendChild(row);
  }

  root.appendChild(menu);

  // Force layout, then trigger the open transition.
  // eslint-disable-next-line no-unused-expressions
  menu.offsetHeight;
  menu.classList.add('visible');

  await sleep(950);

  menu.classList.remove('visible');
  await sleep(180);
  menu.remove();
}
