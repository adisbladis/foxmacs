window.__foxmacs ??= {
  targets: [],
  fields: [],
  hinted: [],
  overlay: null,
  box: null,

  call(fn, args) {
    if (["call", "target", "flash", "describe"].includes(fn) || typeof this[fn] !== "function") {
      throw new Error(`Unknown page function ${fn}`);
    }
    return this[fn](...args);
  },

  target(id) {
    const el = this.targets[id];
    if (!el?.isConnected) throw new Error("That element is gone from the page");
    return el;
  },

  flash(el) {
    el.animate([{ outline: "3px solid #f80" }, { outline: "3px solid transparent" }], 1000);
  },

  headings() {
    this.targets = [...document.querySelectorAll("h1, h2, h3, h4, h5, h6, [role=heading]")].filter(
      (el) => el.getClientRects().length > 0,
    );
    return this.targets
      .map((el, id) => ({
        id,
        level: Number(el.getAttribute("aria-level") || el.tagName.slice(1)) || 2,
        text: el.textContent.replace(/\s+/g, " ").trim(),
      }))
      .filter((heading) => heading.text);
  },

  blocks() {
    const display = new Map();
    const blockOf = (el) => {
      while (el.parentElement && el !== document.body) {
        if (!display.has(el)) display.set(el, getComputedStyle(el).display);
        if (!display.get(el).startsWith("inline")) break;
        el = el.parentElement;
      }
      return el;
    };
    const texts = new Map();
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!node.data.trim() || node.parentElement.closest("script, style, noscript, template")) continue;
      const block = blockOf(node.parentElement);
      if (!texts.has(block)) texts.set(block, []);
      texts.get(block).push(node.data);
    }
    this.targets = [];
    const blocks = [];
    for (const [el, parts] of texts) {
      const text = parts.join("").replace(/\s+/g, " ").trim();
      if (!text || el.getClientRects().length === 0) continue;
      blocks.push({ id: this.targets.push(el) - 1, text });
    }
    return blocks;
  },

  scrollTo(id) {
    const el = this.target(id);
    el.scrollIntoView({ block: "start" });
    this.flash(el);
  },

  reveal(id, term) {
    const el = this.target(id);
    const selection = window.getSelection();
    el.scrollIntoView({ block: "center" });
    if (term) {
      selection.collapse(el, 0);
      if (window.find(term, false, false, false, false, false, false) && el.contains(selection.anchorNode)) {
        return;
      }
      selection.removeAllRanges();
    }
    this.flash(el);
  },

  position() {
    return { x: window.scrollX, y: window.scrollY };
  },

  restore(x, y) {
    window.scrollTo(x, y);
  },

  field() {
    let el = document.activeElement;
    while (el?.shadowRoot?.activeElement) el = el.shadowRoot.activeElement;
    const isInput = el?.matches?.(
      "textarea, input:not([type]), input[type=text], input[type=search], input[type=email], input[type=url], input[type=tel]",
    );
    if (!isInput && !el?.isContentEditable) return null;
    const id = this.fields.push(el) - 1;
    const focused = document.hasFocus();
    if (!isInput) return { id, focused, text: el.innerText, cursor: null };
    // Count the cursor in code points, like Emacs
    const cursor = typeof el.selectionStart === "number" ? [...el.value.slice(0, el.selectionStart)].length : null;
    return { id, focused, text: el.value, cursor };
  },

  setField(id, text, cursor) {
    const el = this.fields[id];
    if (!el?.isConnected) throw new Error("The text field is gone from the page");
    el.focus();
    if (el.isContentEditable) window.getSelection().selectAllChildren(el);
    else el.select();
    // insertText keeps undo working and fires input events
    const inserted = text ? document.execCommand("insertText", false, text) : document.execCommand("delete");
    if (!inserted && !el.isContentEditable) {
      el.value = text;
      el.dispatchEvent(new Event("input", { bubbles: true }));
    }
    if (!el.isContentEditable && cursor !== null) {
      const at = [...text].slice(0, cursor).join("").length;
      try {
        el.setSelectionRange(at, at);
      } catch {
        // Not every input type supports selection
      }
    }
    el.dispatchEvent(new Event("change", { bubbles: true }));
  },

  hintCollect() {
    this.hintClear();
    const selector = [
      "a[href]", "button", "input:not([type=hidden])", "textarea", "select", "summary",
      "[contenteditable='']", "[contenteditable=true]", "[onclick]", "[tabindex]:not([tabindex='-1'])",
      ...["button", "link", "tab", "menuitem", "checkbox", "radio", "option", "switch"].map((r) => `[role=${r}]`),
    ].join(", ");
    const [vw, vh] = [window.innerWidth, window.innerHeight];
    const found = [];
    for (const el of document.querySelectorAll(selector)) {
      if (el.parentElement?.closest("a[href], button")) continue;
      const rect = [...el.getClientRects()].find(
        (r) => r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 && r.top < vh && r.left < vw,
      );
      if (!rect) continue;
      // Skip covered elements
      const hit = document.elementFromPoint(
        (Math.max(rect.left, 0) + Math.min(rect.right, vw)) / 2,
        (Math.max(rect.top, 0) + Math.min(rect.bottom, vh)) / 2,
      );
      if (hit && hit !== el && !el.contains(hit) && !hit.contains(el) && hit.closest("label")?.control !== el) continue;
      found.push({ el, rect });
    }
    this.hinted = found;
    return found.map(({ el }, id) => ({
      id,
      kind: el.getAttribute("role") || { A: "link", BUTTON: "button", INPUT: el.type }[el.tagName] || el.tagName.toLowerCase(),
      text: this.describe(el),
      href: typeof el.href === "string" && !el.href.startsWith("javascript:") ? el.href : null,
      newWindow: el.target === "_blank",
    }));
  },

  hintDraw(labels) {
    const host = document.createElement("div");
    host.style.cssText = "position:absolute;top:0;left:0;z-index:2147483647;pointer-events:none";
    const root = host.attachShadow({ mode: "closed" });
    root.innerHTML = `<style>
      .hint { position: absolute; font: bold 12px/1.3 monospace; padding: 0 3px; color: #302505;
              background: #ffd76e; border: 1px solid #c38a22; border-radius: 3px;
              box-shadow: 0 1px 3px rgba(0, 0, 0, .3); white-space: pre }
      .hint[hidden] { display: none }
      .hint .typed { opacity: .4 }
      .hint.selected { background: #f80; border-color: #b45309; color: #fff; z-index: 1 }
      .box { position: absolute; border: 2px solid #f80; border-radius: 3px }
    </style>`;
    this.hinted = this.hinted.map(({ el, rect }, id) => {
      const badge = document.createElement("span");
      badge.className = "hint";
      badge.style.left = `${Math.max(rect.left, 0) + window.scrollX}px`;
      badge.style.top = `${Math.max(rect.top, 0) + window.scrollY}px`;
      const typed = badge.appendChild(document.createElement("span"));
      typed.className = "typed";
      const rest = badge.appendChild(document.createTextNode(labels[id]));
      root.appendChild(badge);
      return { el, label: labels[id], badge, typed, rest };
    });
    this.box = root.appendChild(document.createElement("div"));
    this.box.className = "box";
    this.box.hidden = true;
    document.documentElement.appendChild(host);
    this.overlay = host;
  },

  describe(el) {
    const field = el.matches("input:not([type=button], [type=submit], [type=reset]), textarea, select");
    const text =
      // Never send field values to Emacs
      (field ? "" : el.innerText || el.value) ||
      el.getAttribute("aria-label") ||
      el.labels?.[0]?.innerText ||
      el.title ||
      el.placeholder ||
      el.querySelector?.("img[alt]")?.alt ||
      el.name ||
      "";
    return text.replace(/\s+/g, " ").trim().slice(0, 200);
  },

  hintFilter(ids, typed) {
    const show = new Set(ids);
    this.hinted.forEach((hint, id) => {
      hint.badge.hidden = !show.has(id);
      const n = typed && hint.label.startsWith(typed) ? typed.length : 0;
      hint.typed.textContent = hint.label.slice(0, n);
      hint.rest.textContent = hint.label.slice(n);
    });
  },

  hintSelect(id) {
    this.hinted.forEach((hint, i) => hint.badge.classList.toggle("selected", i === id));
    const rect = this.hinted[id]?.el.getBoundingClientRect();
    if (!this.box) return;
    this.box.hidden = !rect;
    if (rect) {
      Object.assign(this.box.style, {
        left: `${rect.left + window.scrollX - 2}px`,
        top: `${rect.top + window.scrollY - 2}px`,
        width: `${rect.width}px`,
        height: `${rect.height}px`,
      });
    }
  },

  hintClear() {
    // hintAct still needs this.hinted
    this.overlay?.remove();
    this.overlay = null;
    this.box = null;
  },

  hintAct(id, action) {
    const el = this.hinted[id]?.el;
    if (!el?.isConnected) throw new Error("That element is gone from the page");
    this.hintClear();
    const typing = el.isContentEditable ||
      el.matches("textarea, select, input:not([type=button], [type=submit], [type=reset], [type=checkbox], [type=radio], [type=file], [type=image], [type=color], [type=range])");
    if (action === "focus" || typing) {
      el.focus();
      return;
    }
    for (const type of ["mousedown", "mouseup"]) {
      el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true }));
    }
    el.click();
  },

  selection() {
    // getSelection() doesn't see selections in form fields
    const el = document.activeElement;
    if (el && typeof el.selectionStart === "number" && el.selectionStart !== el.selectionEnd) {
      return el.value.slice(el.selectionStart, el.selectionEnd);
    }
    return window.getSelection().toString();
  },
};

// executeScript returns the last value, which must be cloneable
undefined;
