// Emacs sends {id, method, params}; we answer {id, result} or {id, error}.

async function activeTab(windowId) {
  const [tab] = await browser.tabs.query({ windowId, active: true });
  if (!tab) throw new Error(`No Firefox window ${windowId}`);
  return tab;
}

async function run(tab, details) {
  try {
    return await browser.tabs.executeScript(tab.id, details);
  } catch (e) {
    if (String(e?.message).startsWith("Missing host permission")) {
      throw new Error(`Firefox doesn't let extensions read ${tab.url}`);
    }
    throw e;
  }
}

async function callPage(tab, frameId, fn, args) {
  const where = { frameId, matchAboutBlank: true };
  await run(tab, { file: "/page.js", ...where });
  const [result] = await run(tab, {
    code: `window.__foxmacs.call(${JSON.stringify(fn)}, ${JSON.stringify(args)})`,
    ...where,
  });
  return result;
}

const methods = {
  async windows() {
    const tabs = await browser.tabs.query({ active: true });
    return tabs.map((tab) => ({ id: tab.windowId, url: tab.url, title: tab.title }));
  },

  async window({ window }) {
    const tab = await activeTab(window);
    return { id: window, url: tab.url, title: tab.title };
  },

  async history({ max = 10000 }) {
    const items = await browser.history.search({ text: "", startTime: 0, maxResults: max });
    return items.map(({ url, title }) => ({ url, title }));
  },

  async bookmarks() {
    const items = await browser.bookmarks.search({});
    return items.filter((item) => item.url).map(({ url, title }) => ({ url, title }));
  },

  async closed() {
    const sessions = await browser.sessions.getRecentlyClosed();
    return sessions.flatMap(({ tab, window }) => {
      const shown = tab ?? window.tabs?.find((t) => t.active) ?? window.tabs?.[0];
      return shown ? [{ id: tab?.sessionId ?? window.sessionId, url: shown.url, title: shown.title }] : [];
    });
  },

  async restore({ id }) {
    await browser.sessions.restore(id);
  },

  async open({ window, url }) {
    if (window === undefined) await browser.windows.create({ url });
    else await browser.tabs.update((await activeTab(window)).id, { url });
  },

  async search({ window, text }) {
    if (window === undefined) await browser.search.query({ text, disposition: "NEW_WINDOW" });
    else await browser.search.query({ text, tabId: (await activeTab(window)).id });
  },

  async article({ window }) {
    const tab = await activeTab(window);
    await run(tab, { file: "/node_modules/@mozilla/readability/Readability.js" });
    const [article] = await run(tab, {
      code: `(() => {
        const a = new Readability(document.cloneNode(true)).parse();
        return a && { title: a.title, byline: a.byline, siteName: a.siteName, content: a.content };
      })()`,
    });
    if (!article) throw new Error("No article found on this page");
    return { url: tab.url, ...article };
  },

  async page({ window, fn, args = [], frame = 0 }) {
    return callPage(await activeTab(window), frame, fn, args);
  },

  // Errors in subframes are ignored
  async pageAll({ window, fn, args = [] }) {
    const tab = await activeTab(window);
    const frames = (await browser.webNavigation.getAllFrames({ tabId: tab.id }))
      .map(({ frameId }) => frameId)
      .sort((a, b) => a - b);
    const results = await Promise.all(
      frames.map((frame) =>
        callPage(tab, frame, fn, args).then(
          (result) => ({ frame, result }),
          (e) => {
            if (frame === 0) throw e;
            return null;
          },
        ),
      ),
    );
    return results.filter(Boolean);
  },

  async eval({ window, code }) {
    const tab = await activeTab(window);
    const [result] = await run(tab, { code });
    return result;
  },
};

async function handle(port, { id, method, params }) {
  try {
    if (!Object.hasOwn(methods, method)) throw new Error(`Unknown method ${method}`);
    const result = await methods[method](params ?? {});
    port.postMessage({ id, result: result ?? null });
  } catch (e) {
    port.postMessage({ id, error: String(e?.message ?? e) });
  }
}

// The host blocks until Emacs listens, so back off if it keeps exiting
let delay = 1000;
function connect() {
  const started = Date.now();
  const port = browser.runtime.connectNative("foxmacs");
  port.onMessage.addListener((message) => handle(port, message));
  port.onDisconnect.addListener(() => {
    delay = Date.now() - started > 10000 ? 1000 : Math.min(delay * 2, 60000);
    setTimeout(connect, delay);
  });
}
connect();

// Emacs finds windows by the id in their title
function tag(win) {
  browser.windows.update(win.id, { titlePreface: `[ff:${win.id}] ` }).catch(() => {});
}
browser.windows.onCreated.addListener(tag);
browser.windows.getAll().then((wins) => wins.forEach(tag));
