// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/jc"
import topbar from "../vendor/topbar"

// CodeMirror 5 file editor: progressively enhance <textarea phx-hook="CodeEditor"> into a code
// editor (line numbers + syntax by file extension). If CM5 isn't loaded, the textarea still works.
const Hooks = {}
Hooks.CodeEditor = {
  mounted() { this.init() },
  updated() { this.init() },
  destroyed() { if (this.cm) { this.cm.toTextArea(); this.cm = null } },
  init() {
    if (!window.CodeMirror || this.cm) return
    const ext = this.el.dataset.ext || ""
    const modes = {".js":"javascript",".mjs":"javascript",".ts":"javascript",".jsx":"javascript",".tsx":"javascript",".json":{name:"javascript",json:true},".py":"python",".rb":"ruby",".ex":"ruby",".exs":"ruby",".jet":"ruby",".gleam":"clike",".md":"markdown",".markdown":"markdown",".c":"text/x-csrc",".h":"text/x-csrc",".cpp":"text/x-c++src",".java":"text/x-java",".css":"css",".scss":"css",".xml":"xml",".html":"xml",".heex":"xml",".eex":"xml"}
    this.cm = window.CodeMirror.fromTextArea(this.el, {lineNumbers: true, mode: modes[ext] || null, theme: this.el.dataset.dark === "true" ? "material-darker" : "default", viewportMargin: Infinity})
    this.cm.setSize("100%", "100%")
    this.cm.on("change", () => this.cm.save())   // sync to the textarea so phx-submit sends the edits
  },
}

// xterm.js terminal: stream a PTY-backed shell (server-side) <-> the terminal widget.
Hooks.Terminal = {
  mounted() { this.tries = 0; this.boot() },
  boot() {
    if (!window.Terminal) {                       // xterm.js still loading? retry briefly
      if (this.tries++ < 20) return setTimeout(() => this.boot(), 100)
      this.el.innerHTML = "<div style='color:#f88;padding:1rem;font-family:monospace'>xterm.js not loaded</div>"
      return
    }
    const term = new window.Terminal({fontSize: 13, fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", cursorBlink: true, theme: {background: "#1b1b1f", foreground: "#e7e7ea"}})
    this.term = term
    term.open(this.el)
    const tid = this.el.dataset.tid                 // per-thread terminal id
    this.tid = tid
    try {                                          // fit addon is best-effort (UMD exposes it as FitAddon or FitAddon.FitAddon)
      const FA = window.FitAddon && (window.FitAddon.FitAddon || window.FitAddon)
      if (FA) { this.fit = new FA(); term.loadAddon(this.fit) }
    } catch (e) {}
    term.onData(d => this.pushEvent("term_input", {d, tid}))
    this.handleEvent("term_output", ({d}) => term.write(d))
    // fit to the pane FIRST, then open the PTY at that initial size...
    setTimeout(() => {
      if (this.fit) { try { this.fit.fit() } catch (e) {} }
      const t = this.term
      this._cols = t && t.cols; this._rows = t && t.rows
      this.pushEvent("term_ready", {tid, cols: this._cols || 120, rows: this._rows || 30})
    }, 0)
    // ...then follow pane changes: re-fit the display + push the new size (the server resizes the
    // PTY out-of-band via `stty -f`, so this is safe even with a foreground program running).
    this._onresize = () => this.refit()
    window.addEventListener("resize", this._onresize)
    try { this._ro = new ResizeObserver(this._onresize); this._ro.observe(this.el) } catch (e) {}
  },
  refit() {
    if (this.fit) { try { this.fit.fit() } catch (e) {} }
    const t = this.term
    if (!t || !t.cols || !t.rows || (t.cols === this._cols && t.rows === this._rows)) return
    this._cols = t.cols; this._rows = t.rows
    clearTimeout(this._sz)
    this._sz = setTimeout(() => this.pushEvent("term_resize", {tid: this.tid, cols: t.cols, rows: t.rows}), 150)
  },
  destroyed() {
    window.removeEventListener("resize", this._onresize)
    if (this._ro) { try { this._ro.disconnect() } catch (e) {} }
    if (this.term) this.term.dispose()
  },
}

// Rich markdown block: owns its DOM (phx-update="ignore"), renders the server's HTML from
// data-html, then syntax-highlights code blocks (highlight.js) and renders ```mermaid diagrams.
Hooks.Rich = {
  mounted() { this.render() },
  updated() { clearTimeout(this._t); this._t = setTimeout(() => this.render(), 250) },   // process after streaming settles
  render() {
    if (window.hljs) {
      this.el.querySelectorAll("pre code[class]:not(.mermaid):not([data-hl])").forEach(el => {
        try { window.hljs.highlightElement(el); el.setAttribute("data-hl", "1") } catch (e) {}
      })
    }
    // mermaid's vendored build exposes `__esbuild_esm_mermaid` (not window.mermaid) -> resolve it
    const mermaid = window.mermaid || (window.__esbuild_esm_mermaid && (window.__esbuild_esm_mermaid.default || window.__esbuild_esm_mermaid))
    if (mermaid) {
      if (!window.__mermaidInit) {
        try { mermaid.initialize({startOnLoad: false, theme: "dark", securityLevel: "loose"}) } catch (e) {}
        window.__mermaidInit = true
      }
      this.el.querySelectorAll("pre code.mermaid").forEach(async (el) => {
        const pre = el.closest("pre")
        if (!pre || pre.dataset.mm) return
        pre.dataset.mm = "1"
        try {
          const {svg} = await mermaid.render("mmd" + Math.floor(Math.random() * 1e9), el.textContent)
          const div = document.createElement("div")
          div.innerHTML = svg
          pre.replaceWith(div)
        } catch (e) { pre.dataset.mm = "" }   // invalid while still streaming -> retry on next idle
      })
    }
  },
}

// Bottom dock: drag the top edge to resize (height persisted in --dock-h + localStorage). Re-fit
// the terminal (window 'resize') on drag and on re-render (tab switch). Uses event delegation so it
// survives content re-renders; sets --dock-h on <html> so LiveView patches don't reset the height.
Hooks.DockResize = {
  mounted() {
    const saved = localStorage.getItem("jc_dock_h")
    if (saved) document.documentElement.style.setProperty("--dock-h", saved)
    this.el.addEventListener("mousedown", (e) => {
      if (!e.target.classList.contains("dock-resize")) return
      e.preventDefault()
      const startY = e.clientY, startH = this.el.offsetHeight
      document.body.style.userSelect = "none"
      const onMove = (ev) => {
        const h = Math.max(120, Math.min(window.innerHeight - 140, startH + (startY - ev.clientY)))
        this.el.style.height = h + "px"                                  // immediate, direct
        document.documentElement.style.setProperty("--dock-h", h + "px") // survives LiveView re-renders
      }
      const onUp = () => {
        document.removeEventListener("mousemove", onMove)
        document.removeEventListener("mouseup", onUp)
        document.body.style.userSelect = ""
        localStorage.setItem("jc_dock_h", this.el.style.height)
        window.dispatchEvent(new Event("resize"))
      }
      document.addEventListener("mousemove", onMove)
      document.addEventListener("mouseup", onUp)
    })
  },
  updated() { window.dispatchEvent(new Event("resize")) },
}

// Right inspector panel: drag its left edge to resize width (persisted in --aside-w + localStorage).
Hooks.AsideResize = {
  mounted() {
    const saved = localStorage.getItem("jc_aside_w")
    if (saved) document.documentElement.style.setProperty("--aside-w", saved)
    this.el.addEventListener("mousedown", (e) => {
      if (!e.target.classList.contains("aside-resize")) return
      e.preventDefault()
      const startX = e.clientX, startW = this.el.offsetWidth
      document.body.style.userSelect = "none"
      const onMove = (ev) => {
        const w = Math.max(160, Math.min(window.innerWidth - 320, startW + (startX - ev.clientX)))
        this.el.style.width = w + "px"
        document.documentElement.style.setProperty("--aside-w", w + "px")
      }
      const onUp = () => {
        document.removeEventListener("mousemove", onMove)
        document.removeEventListener("mouseup", onUp)
        document.body.style.userSelect = ""
        localStorage.setItem("jc_aside_w", this.el.style.width)
      }
      document.addEventListener("mousemove", onMove)
      document.addEventListener("mouseup", onUp)
    })
  },
}

// Slash-command autocomplete on the message input: when the value is "/word" (no space yet), show a
// dropdown of the agent's ACP commands (from data-commands), filter as you type, Up/Down + Enter/Tab
// to pick (inserts "/name " so you add args, then Enter sends), Escape closes. Menu lives on <body>
// (so LiveView patches can't remove it) and is position:fixed (no overflow clipping).
Hooks.SlashMenu = {
  mounted() { this.boot() },
  updated() { this.grow(); this.commands = this.parse(); if (!this.commands.length) this.pushEvent("probe_commands", {}) },
  destroyed() { if (this.menu) this.menu.remove() },
  parse() { try { return JSON.parse(this.el.dataset.commands || "[]") } catch (e) { return [] } },
  boot() {
    this.commands = this.parse(); this.sel = 0; this.matches = []
    this.handleEvent("acp_commands", (p) => { this.commands = p.commands || [] })
    if (!this.commands.length) this.pushEvent("probe_commands", {})   // load the / menu before any message
    this.menu = document.createElement("div")
    this.menu.style.cssText = "position:fixed;display:none;z-index:60;max-height:260px;overflow-y:auto;border-radius:.5rem;box-shadow:0 8px 28px rgba(0,0,0,.3);font-size:.8rem"
    document.body.appendChild(this.menu)
    this.el.addEventListener("input", () => { this.grow(); this.onInput() })
    this.el.addEventListener("keydown", (e) => this.onKey(e))
    this.el.addEventListener("blur", () => setTimeout(() => this.hide(), 150))
    this.grow()
  },
  grow() {                                  // auto-size the textarea to its content (up to a cap)
    if (this.el.tagName !== "TEXTAREA") return
    this.el.style.height = "auto"
    this.el.style.height = Math.min(this.el.scrollHeight, 160) + "px"
  },
  open() { return this.menu.style.display !== "none" },
  onInput() {
    const m = this.el.value.match(/^\/(\S*)$/)
    if (!m) return this.hide()
    const q = m[1].toLowerCase()
    this.matches = this.commands.filter(c => (c.name || "").toLowerCase().includes(q))
    if (!this.matches.length) return this.hide()
    this.sel = 0; this.render(); this.show()
  },
  onKey(e) {
    if (!this.open()) {
      // menu closed: Enter sends, Shift+Enter inserts a newline; ignore Enter while composing (IME)
      if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
        e.preventDefault()
        if (this.el.form) this.el.form.requestSubmit()
        this.el.value = ""
        this.grow()
      }
      return
    }
    if (e.key === "ArrowDown") { e.preventDefault(); this.sel = (this.sel + 1) % this.matches.length; this.render() }
    else if (e.key === "ArrowUp") { e.preventDefault(); this.sel = (this.sel - 1 + this.matches.length) % this.matches.length; this.render() }
    else if (e.key === "Enter" || e.key === "Tab") { e.preventDefault(); this.pick(this.sel) }
    else if (e.key === "Escape") { e.preventDefault(); this.hide() }
  },
  pick(i) { const c = this.matches[i]; if (!c) return; this.el.value = "/" + c.name + " "; this.hide(); this.el.focus() },
  esc(s) { return (s || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") },
  // read a chat design token (--card/--tx/--bd2) off the `.jc` container — its `.jc`/`.jc.dark`
  // class is the chat's REAL theme (the page's <html data-theme> is a separate system/daisyUI
  // signal, so keying off it made the menu dark in light mode when the OS was dark).
  tok(name, fallback) {
    const el = document.querySelector(".jc")
    if (!el) return fallback
    const v = getComputedStyle(el).getPropertyValue(name).trim()
    return v || fallback
  },
  render() {
    const hi = "#0b66c3"   // blue selection — readable on both light and dark
    this.menu.innerHTML = this.matches.map((c, i) =>
      `<div data-i="${i}" style="padding:.35rem .6rem;cursor:pointer;${i === this.sel ? `background:${hi};color:#fff` : ""}">` +
      `<div style="font-family:ui-monospace,monospace">/${this.esc(c.name)}</div>` +
      `<div style="font-size:.72rem;opacity:.65;max-width:34rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${this.esc(c.description)}</div></div>`
    ).join("")
    this.menu.querySelectorAll("[data-i]").forEach(el =>
      el.addEventListener("mousedown", (ev) => { ev.preventDefault(); this.pick(parseInt(el.dataset.i)) }))
  },
  show() {
    this.menu.style.background = this.tok("--card", "#ffffff")
    this.menu.style.color = this.tok("--tx", "#1a1a1a")
    this.menu.style.border = "1px solid " + this.tok("--bd2", "#d8d8de")
    const r = this.el.getBoundingClientRect()
    this.menu.style.left = r.left + "px"
    this.menu.style.width = r.width + "px"
    this.menu.style.bottom = (window.innerHeight - r.top + 6) + "px"
    this.menu.style.maxHeight = Math.max(140, r.top - 16) + "px"
    this.menu.style.display = "block"
  },
  hide() { if (this.menu) this.menu.style.display = "none" },
}

// P4: completion awareness — a background turn finishing (or needing approval) badges the tab,
// fires a desktop notification, and chimes, so you can leave the tab and get pinged when it's done.
Hooks.Notify = {
  mounted() {
    this.unseen = 0
    this.base = (document.title || "Jet Console").replace(/^\(\d+\)\s*/, "")
    // browsers require a user gesture to ask for desktop-notification permission
    const ask = () => {
      if ("Notification" in window && Notification.permission === "default") Notification.requestPermission()
      document.removeEventListener("click", ask)
    }
    document.addEventListener("click", ask, { once: true })
    // clear the tab badge when the user comes back to the window
    this._focus = () => { this.unseen = 0; document.title = this.base }
    window.addEventListener("focus", this._focus)
    // server pushes "notify" when a BACKGROUND thread finishes / needs approval
    this.handleEvent("notify", ({ title, body, sound }) => {
      const away = !document.hasFocus() || document.hidden   // another app (unfocused) OR a background tab (hidden)
      if (!away) return   // you're at the window — the status dots / board already show it
      this.unseen += 1
      document.title = `(${this.unseen}) ${this.base}`
      if ("Notification" in window && Notification.permission === "granted") {
        const t = title || "Jet Console", opts = { body: body || "", tag: "jet-console", renotify: true }
        // prefer the service worker (works from a background tab); fall back to the constructor
        if (navigator.serviceWorker) {
          navigator.serviceWorker.ready
            .then((reg) => reg.showNotification(t, opts))
            .catch(() => { try { new Notification(t, opts) } catch (e) {} })
        } else {
          try { new Notification(t, opts) } catch (e) {}
        }
      }
      if (sound) this.beep()
    })
  },
  destroyed() { if (this._focus) window.removeEventListener("focus", this._focus) },
  beep() {
    try {
      const ctx = new (window.AudioContext || window.webkitAudioContext)()
      const o = ctx.createOscillator(), g = ctx.createGain()
      o.connect(g); g.connect(ctx.destination)
      o.type = "sine"; o.frequency.value = 680; g.gain.value = 0.04
      o.start(); o.stop(ctx.currentTime + 0.12)
      o.onended = () => ctx.close()
    } catch (e) {}
  }
}

// register a service worker so desktop notifications can fire from a BACKGROUND tab (browsers block
// new Notification() from a hidden tab; ServiceWorkerRegistration.showNotification works there)
if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

