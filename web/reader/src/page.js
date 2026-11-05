// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

// Everything the reader's page does. It's injected as a user script, because
// the page's Content Security Policy allows no scripts of its own: a note can
// hold raw HTML, and nothing in a note may run. window.stenmark is what the app
// calls.
const root = document.documentElement;
const post = (name, value) => window.webkit.messageHandlers[name].postMessage(value);

const COPY_ICON = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>';

document.addEventListener("change", (event) => {
  const box = event.target;
  if (!box.matches || !box.matches("input[data-task-line]")) return;
  post("checkboxToggled", JSON.stringify({
    line: Number(box.dataset.taskLine),
    checked: box.checked,
  }));
});

for (const pre of document.querySelectorAll("pre")) {
  const button = document.createElement("button");
  button.className = "copy-btn";
  button.title = root.dataset.copyLabel;
  button.innerHTML = COPY_ICON;
  button.addEventListener("click", () => {
    // Exactly what the block holds. Linux drops blank lines and anything
    // starting with #, which loses comments and #include lines.
    post("copyCode", (pre.querySelector("code") || pre).textContent);
    button.textContent = root.dataset.copiedLabel;
    button.classList.add("copied");
    setTimeout(() => {
      button.innerHTML = COPY_ICON;
      button.classList.remove("copied");
    }, 1500);
  });
  pre.appendChild(button);
}

document.addEventListener("dblclick", (event) => {
  if (root.dataset.editOnDoubleClick !== "true") return;
  // Links, checkboxes and the copy button have their own behaviour.
  if (event.target.closest("a, input, button")) return;
  const block = event.target.closest("[data-source-line]");
  // The double click selected a word, so the editor can land on it rather than
  // at the start of the block.
  post("editRequest", JSON.stringify({
    line: block ? Number(block.dataset.sourceLine) : 0,
    word: String(window.getSelection() || "").trim().slice(0, 80),
  }));
});

const lineBlocks = () => document.querySelectorAll("[data-source-line]");

function unmark() {
  for (const mark of document.querySelectorAll("mark.sf-match")) {
    const parent = mark.parentNode;
    while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
    parent.removeChild(mark);
    parent.normalize();
  }
}

function highlightMatch(index) {
  const marks = document.querySelectorAll("mark.sf-match");
  if (!marks.length) return { count: 0, current: -1 };
  marks.forEach((mark) => mark.classList.remove("sf-current"));
  marks[index].classList.add("sf-current");
  marks[index].scrollIntoView({ block: "center" });
  return { count: marks.length, current: index };
}

window.stenmark = {
  // The source line of the first block still visible at the top.
  topSourceLine() {
    for (const block of lineBlocks()) {
      if (block.getBoundingClientRect().bottom > 0) return Number(block.dataset.sourceLine) || 1;
    }
    return 1;
  },

  scrollToSourceLine(line, smooth) {
    let best = null;
    for (const block of lineBlocks()) {
      if (Number(block.dataset.sourceLine) > line) break;
      best = block;
    }
    if (best) best.scrollIntoView({ behavior: smooth ? "smooth" : "auto", block: "start" });
  },

  // From the page, not the source, so that every heading on the page is in the
  // list and each one knows its own line.
  headings() {
    return [...document.querySelectorAll("h1, h2, h3, h4, h5, h6")].map((heading) => ({
      level: Number(heading.tagName[1]),
      title: heading.textContent,
      line: Number(heading.dataset.sourceLine) || 0,
    }));
  },

  find(query) {
    unmark();
    if (!query) return { count: 0, current: -1 };
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const lower = query.toLowerCase();
    const ranges = [];
    while (walker.nextNode()) {
      const node = walker.currentNode;
      if (node.parentElement.closest("style, script, button")) continue;
      const text = node.textContent.toLowerCase();
      for (let at = text.indexOf(lower); at !== -1; at = text.indexOf(lower, at + 1)) {
        ranges.push({ node, start: at, end: at + query.length });
      }
    }
    // In reverse, so that wrapping one doesn't move the ones before it.
    for (const { node, start, end } of ranges.reverse()) {
      const range = document.createRange();
      range.setStart(node, start);
      range.setEnd(node, end);
      const mark = document.createElement("mark");
      mark.className = "sf-match";
      range.surroundContents(mark);
    }
    return highlightMatch(0);
  },

  findGoTo: highlightMatch,
  findClear: unmark,
};
