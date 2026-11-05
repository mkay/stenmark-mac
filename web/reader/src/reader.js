// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-only

// The Markdown renderer. It replaces Python-Markdown and Pygments, which the
// Linux app uses and a Swift app can't ship. Rendering only decides how a note
// looks; nothing here ever writes to a file.
import MarkdownIt from "markdown-it";
import attrs from "markdown-it-attrs";
import hljs from "highlight.js/lib/common";

// Guessing the language of a long unlabelled block is slow, and a wrong guess
// is worth less the longer the block is.
const MAX_GUESS_LENGTH = 20000;

function highlight(code, lang) {
  try {
    if (lang && hljs.getLanguage(lang)) {
      return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
    }
    if (!lang && code.length <= MAX_GUESS_LENGTH) {
      return hljs.highlightAuto(code).value;
    }
  } catch (_error) {
    // Falls through to markdown-it's own escaping: plain text beats no text.
  }
  return "";
}

// Python-Markdown takes any line starting with # as a heading, with or without
// the space CommonMark insists on, and notes rely on that. The stock rule still
// handles "# Title"; this one only sees what it turned down. A shebang and
// "#!" generally aren't headings, so those stay text.
function looseHeading(state, startLine, _endLine, silent) {
  const start = state.bMarks[startLine] + state.tShift[startLine];
  const max = state.eMarks[startLine];
  if (state.sCount[startLine] - state.blkIndent >= 4) return false;
  const line = state.src.slice(start, max);
  const match = /^(#{1,6})([^#\s!].*?)\s*#*\s*$/.exec(line);
  if (!match) return false;
  if (silent) return true;

  state.line = startLine + 1;
  const level = match[1].length;
  const open = state.push("heading_open", `h${level}`, 1);
  open.markup = match[1];
  open.map = [startLine, state.line];
  const inline = state.push("inline", "", 0);
  inline.content = match[2].trim();
  inline.map = [startLine, state.line];
  inline.children = [];
  state.push("heading_close", `h${level}`, -1).markup = match[1];
  return true;
}

// markdown-it-attrs reads "{: .note}" as ".note" plus an attribute called ":".
// That colon is Python-Markdown's spelling, not an attribute.
function dropColonAttr(state) {
  for (const token of state.tokens) {
    if (token.attrs) token.attrs = token.attrs.filter(([name]) => name !== ":");
  }
}

// Every checkbox carries the source line of its own "[ ]", so toggling one can
// go straight to that line. Linux counts them by position instead, which goes
// wrong when a code block contains a line that looks like a task.
function taskLists(state) {
  const tokens = state.tokens;
  for (let i = 2; i < tokens.length; i++) {
    const inline = tokens[i];
    if (inline.type !== "inline" || tokens[i - 1].type !== "paragraph_open") continue;
    const item = tokens[i - 2];
    if (item.type !== "list_item_open") continue;
    const match = /^\[([ xX])\](\s|$)/.exec(inline.content);
    const first = inline.children[0];
    if (!match || !first || first.type !== "text") continue;

    item.attrJoin("class", "task-item");
    first.content = first.content.replace(/^\[[ xX]\]\s*/, "");
    const box = new state.Token("html_inline", "", 0);
    const checked = match[1] === " " ? "" : " checked";
    box.content = `<input type="checkbox"${checked} data-task-line="${inline.map[0] + 1}"> `;
    inline.children.unshift(box);
  }
}

// Python-Markdown accepts spaces in a link target and CommonMark doesn't, and
// links between notes are full of them: [x](../Some Folder/My Note.md). If the
// stock parser stops at a space, take everything up to the closing bracket,
// leaving any link title for the link rule to read.
function spacedDestination(parse) {
  return (text, start, max) => {
    const result = parse(text, start, max);
    if (result.ok && text[result.pos] !== " ") return result;
    if (text[start] === "<") return result;

    let depth = 0;
    for (let pos = start; pos < max; pos++) {
      const char = text[pos];
      if (char === "\n") break;
      if (char === "(") depth++;
      if (char === ")") {
        if (depth === 0) {
          const title = text.slice(start, pos).search(/\s+["'(]/);
          const target = text.slice(start, title < 0 ? pos : start + title).trimEnd();
          if (!target) return result;
          return { ok: true, pos: start + target.length, str: target };
        }
        depth--;
      }
    }
    return result;
  };
}

// The same three replacements as Python-Markdown's smarty. markdown-it's own
// rule also turns ".." into an ellipsis, which mangles "../folder", and
// rewrites (c), (tm) and +-, which Linux leaves alone.
function dashesAndDots(state) {
  for (const block of state.tokens) {
    if (block.type !== "inline") continue;
    for (const token of block.children) {
      if (token.type !== "text") continue;
      token.content = token.content
        .replace(/---/g, "\u2014")
        .replace(/--/g, "\u2013")
        .replace(/\.\.\./g, "\u2026");
    }
  }
}

function makeRenderer() {
  const md = new MarkdownIt({ html: true, typographer: true, linkify: false, highlight });
  md.use(attrs);
  md.helpers.parseLinkDestination = spacedDestination(md.helpers.parseLinkDestination);
  md.core.ruler.at("replacements", dashesAndDots);
  md.block.ruler.after("heading", "loose_heading", looseHeading, {
    alt: ["paragraph", "reference", "blockquote"],
  });
  md.core.ruler.push("drop_colon_attr", dropColonAttr);
  md.core.ruler.push("task_lists", taskLists);
  return md;
}

const md = makeRenderer();

// Table rows and cells are left out: nothing scrolls to them, and they would
// only make the reader's "topmost visible block" lookup slower.
const LINE_TAGGED = new Set([
  "paragraph_open", "heading_open", "bullet_list_open", "ordered_list_open",
  "list_item_open", "blockquote_open", "table_open", "fence", "code_block", "hr",
]);

// lineOffset is the number of lines the frontmatter took up, because the source
// lines must count from the top of the file, not the top of the body.
function render(body, lineOffset = 0) {
  const env = {};
  const tokens = md.parse(body, env);
  for (const token of tokens) {
    if (token.map && LINE_TAGGED.has(token.type)) {
      token.attrSet("data-source-line", String(token.map[0] + 1 + lineOffset));
    }
    // Inline tokens hold the checkbox, whose line was set before the offset.
    if (lineOffset && token.type === "inline") {
      for (const child of token.children ?? []) {
        if (child.type === "html_inline" && child.content.includes("data-task-line")) {
          child.content = child.content.replace(
            /data-task-line="(\d+)"/,
            (_all, line) => `data-task-line="${Number(line) + lineOffset}"`,
          );
        }
      }
    }
  }
  return md.renderer.render(tokens, md.options, env);
}

globalThis.StenmarkReader = { render };
