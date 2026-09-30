// The page of the studio: LiveView, an editor (CodeMirror 6 from esm.sh,
// or a text area when it does not load), and the frame of the app.
import { Socket } from "../../pkg/phoenix.js";
import { LiveSocket } from "../../pkg/phoenix_live_view.js";

// The path of the site: this file is at BASE/__studio/static/studio/.
const base = new URL("../../../", import.meta.url).pathname.replace(/\/$/, "");
const CM = "https://esm.sh/";

let codemirror = null;
function loadCodeMirror() {
  codemirror ??= Promise.all([
    import(`${CM}codemirror@6.0.2`),
    import(`${CM}@codemirror/view@6`),
    import(`${CM}@codemirror/state@6`),
    import(`${CM}@codemirror/lang-javascript@6`),
    import(`${CM}@codemirror/lang-css@6`),
    import(`${CM}@codemirror/lang-html@6`),
    import(`${CM}codemirror-lang-elixir@4`),
    import(`${CM}@codemirror/theme-one-dark@6`),
  ]).then(([cm, view, state, js, css, html, elixir, dark]) => ({ cm, view, state, js, css, html, elixir, dark }));
  return codemirror;
}

function language(m, path) {
  if (/\.(ex|exs)$/.test(path)) return m.elixir.elixir();
  if (/\.(heex|eex|html)$/.test(path)) return m.html.html();
  if (/\.(js|mjs|ts|json)$/.test(path)) return m.js.javascript();
  if (/\.css$/.test(path)) return m.css.css();
  return [];
}

// A line to show after the next "open": the line of a problem.
let pendingLine = null;
document.addEventListener("click", (e) => {
  const d = e.target.closest(".diag[data-line]");
  if (d) pendingLine = Number(d.dataset.line) || null;
}, true);

const Editor = {
  mounted() {
    this.path = null;
    this.view = null;
    this.area = null;
    // For scripts and tests: window.studio.editor.text(), .setText(text).
    window.studio = { ...window.studio, editor: this };
    this.handleEvent("open", ({ path, text }) => this.open(path, text));
    this.onSave = (e) => { if (e.target.closest("[data-save]")) this.save(); };
    this.onKey = (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key === "s") { e.preventDefault(); this.save(); }
    };
    document.addEventListener("click", this.onSave);
    document.addEventListener("keydown", this.onKey);
    this.ready = Promise.race([
      loadCodeMirror().catch(() => null),
      new Promise((r) => setTimeout(() => r(null), 10000)),
    ]);
  },
  destroyed() {
    document.removeEventListener("click", this.onSave);
    document.removeEventListener("keydown", this.onKey);
  },
  text() {
    return this.view ? this.view.state.doc.toString() : this.area?.value ?? "";
  },
  setText(text) {
    if (this.view) this.view.dispatch({ changes: { from: 0, to: this.view.state.doc.length, insert: text } });
    else if (this.area) this.area.value = text;
  },
  save() {
    if (this.path) this.pushEvent("save", { path: this.path, text: this.text() });
  },
  async open(path, text) {
    this.path = path;
    const m = await this.ready;
    if (this.path !== path) return;
    const line = pendingLine;
    pendingLine = null;
    if (!m) return this.openArea(text);
    const dark = matchMedia("(prefers-color-scheme: dark)").matches;
    const state = m.state.EditorState.create({
      doc: text,
      extensions: [m.cm.basicSetup, language(m, path), dark ? m.dark.oneDark : [],
                   m.view.EditorView.theme({ "&": { height: "100%" }, ".cm-scroller": { overflow: "auto" } })],
    });
    if (this.view) this.view.setState(state);
    else this.view = new m.view.EditorView({ state, parent: this.el });
    if (line) {
      const l = this.view.state.doc.line(Math.min(line, this.view.state.doc.lines));
      this.view.dispatch({ selection: { anchor: l.from }, scrollIntoView: true });
      this.view.focus();
    }
  },
  openArea(text) {
    if (!this.area) {
      this.area = document.createElement("textarea");
      this.area.spellcheck = false;
      this.area.setAttribute("aria-label", "The text of the file");
      this.el.append(this.area);
    }
    this.area.value = text;
  },
};

const Preview = {
  mounted() {
    this.frame = this.el.querySelector("iframe");
    this.address = this.el.querySelector(".address");
    this.handleEvent("reload", () => { this.frame.src = base + (this.address.value || "/"); });
    this.address.addEventListener("keydown", (e) => {
      if (e.key !== "Enter") return;
      const path = this.address.value.startsWith("/") ? this.address.value : `/${this.address.value}`;
      this.frame.src = base + path;
    });
    this.frame.addEventListener("load", () => {
      try {
        const loc = this.frame.contentWindow.location;
        const path = loc.pathname.startsWith(base) ? loc.pathname.slice(base.length) || "/" : loc.pathname;
        if (document.activeElement !== this.address) this.address.value = path + loc.search;
      } catch { /* another origin */ }
    });
  },
};

// The IEx line: it clears after each submit (LiveView reads the value at
// the submit), and the arrow keys go through the history of the session.
const IexLine = {
  mounted() {
    const input = this.el.querySelector("input");
    const history = [];
    let at = 0;
    this.el.addEventListener("submit", () => {
      if (input.value.trim()) history.push(input.value);
      at = history.length;
      setTimeout(() => { input.value = ""; }, 0);
    });
    input.addEventListener("keydown", (e) => {
      if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return;
      e.preventDefault();
      at = Math.max(0, Math.min(history.length, at + (e.key === "ArrowUp" ? -1 : 1)));
      input.value = history[at] ?? "";
    });
  },
};

// A log that shows its last line.
const ScrollEnd = {
  mounted() { this.el.scrollTop = this.el.scrollHeight; },
  updated() { this.el.scrollTop = this.el.scrollHeight; },
};

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
const liveSocket = new LiveSocket(`${base}/__studio/live`, Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: { Editor, Preview, IexLine, ScrollEnd },
});
liveSocket.connect();
window.liveSocket = liveSocket;
