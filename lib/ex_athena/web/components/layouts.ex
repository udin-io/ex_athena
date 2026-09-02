defmodule ExAthena.Web.Layouts do
  use Phoenix.Component
  import Plug.CSRFProtection, only: [get_csrf_token: 0]

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" style="height:100%">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>ExAthena</title>
        <link rel="stylesheet" href="/assets/app.css" />
        <link rel="stylesheet" href="/assets/vendor/xterm/xterm.css" />
        <script src="/assets/vendor/xterm/xterm.js"></script>
        <script src="/assets/vendor/xterm/addon-fit.js"></script>
        <script type="importmap">
          {
            "imports": {
              "phoenix": "/assets/phoenix/phoenix.mjs",
              "phoenix_live_view": "/assets/phoenix_live_view/phoenix_live_view.esm.js"
            }
          }
        </script>
        <script>
          (function(){
            var t = localStorage.getItem("ex_athena.theme")
            if (t) document.documentElement.dataset.theme = t
          })()
        </script>
        <script type="module">
          import {Socket} from "phoenix"
          import {LiveSocket} from "phoenix_live_view"

          // ── LiveView hooks ─────────────────────────────────────────────────
          const THEME_KEY = "ex_athena.theme"
          const applyTheme = (light) => {
            document.documentElement.dataset.theme = light ? "light" : "dark"
            localStorage.setItem(THEME_KEY, light ? "light" : "dark")
          }

          // How close to the bottom still counts as "at the bottom". Large
          // enough to survive fractional-pixel scrollHeight rounding, small
          // enough that a deliberate scroll away always disarms the pin.
          const SCROLL_BOTTOM_PX = 64

          const Hooks = {
            ThemeToggle: {
              mounted() {
                const input = this.el.querySelector("input[type=checkbox]")
                const light = localStorage.getItem(THEME_KEY) === "light"
                if (input) input.checked = light
                document.documentElement.dataset.theme = light ? "light" : "dark"
                if (input) {
                  input.addEventListener("change", () => applyTheme(input.checked))
                }
              }
            },
            // Keeps a scrolling pane stuck to the bottom, but ONLY while the
            // reader is already there. Scrolling up disarms the pin, so a live
            // run can no longer yank the pane out from under someone reading
            // back through the thread.
            //
            // updated() runs on EVERY LiveView diff — and the message list is
            // re-diffed per streamed token — so it must never touch layout.
            // The pinned flag is computed in a passive, rAF-coalesced scroll
            // listener; updated() only reads the cached boolean.
            ScrollToBottom: {
              mounted() {
                this.pinned = true
                this.rafPending = false
                this.onScroll = () => this.measureSoon()
                this.el.addEventListener("scroll", this.onScroll, {passive: true})
                this.stick()
              },

              updated() {
                if (this.pinned) this.stick()
              },

              destroyed() {
                this.el.removeEventListener("scroll", this.onScroll)
              },

              // Both scroll containers set `scroll-behavior: smooth` in CSS, so
              // the jump has to be forced instant: a smooth jump emits
              // intermediate scroll events that read as "not at the bottom",
              // which would disarm the pin mid-flight and never re-arm it.
              stick() {
                this.el.scrollTo({top: this.el.scrollHeight, behavior: "instant"})
              },

              // One layout read per animation frame, no matter how many scroll
              // events fire.
              measureSoon() {
                if (this.rafPending) return
                this.rafPending = true
                requestAnimationFrame(() => {
                  this.rafPending = false
                  const gap = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
                  const atBottom = gap <= SCROLL_BOTTOM_PX
                  if (atBottom === this.pinned) return
                  if (atBottom) this.arm(); else this.disarm()
                })
              },

              arm() {
                this.pinned = true
                this.stick()
              },

              disarm() {
                this.pinned = false
              }
            },

            // A real terminal via xterm.js over the erlexec PTY. The hook
            // owns its DOM (phx-update="ignore"); the server streams raw VT
            // bytes (base64) which xterm renders — neovim, htop, colors,
            // the real prompt, all work. Keystrokes stream back per-char.
            Terminal: {
              mounted() {
                const id = this.el.dataset.termId
                const term = new Terminal({
                  cursorBlink: true,
                  fontFamily: "JetBrains Mono, Fira Code, monospace",
                  fontSize: 12,
                  theme: { background: "#0e0e12", foreground: "#dde1f0" }
                })
                const fit = new FitAddon.FitAddon()
                term.loadAddon(fit)
                term.open(this.el)
                fit.fit()

                this.term = term
                this.fit = fit

                // keystrokes -> server -> pty
                term.onData((data) => this.pushEvent("term_input", { id, data }))

                // pty output (base64 raw bytes) -> xterm
                this.handleEvent("term_out", ({ id: outId, b64 }) => {
                  if (outId !== id) return
                  const bin = atob(b64)
                  const bytes = new Uint8Array(bin.length)
                  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
                  term.write(bytes)
                })

                // fit on container resize. Skip while hidden (display:none →
                // 0 size): fitting at 0 clamps xterm to a tiny grid, so the
                // panel looks resized when shown again.
                const sendResize = () => {
                  if (!this.el.clientWidth || !this.el.clientHeight) return
                  try { this.fit.fit() } catch (_e) { return }
                  this.pushEvent("term_resize", { id, cols: term.cols, rows: term.rows })
                }
                this.ro = new ResizeObserver(sendResize)
                this.ro.observe(this.el)
                sendResize()

                // Re-fit when the Terminal tab is re-activated (a display
                // change doesn't reliably trigger ResizeObserver).
                this.handleEvent("term_fit", () => sendResize())

                // Ask the server to replay captured scrollback (covers the
                // mount race for the first prompt + full reconnects).
                this.pushEvent("term_ready", { id })
              },
              destroyed() {
                this.ro && this.ro.disconnect()
                this.term && this.term.dispose()
              }
            },

            SubmitOnEnter: {
              mounted() {
                this.el.addEventListener("keydown", e => {
                  if (e.key === "Enter" && !e.shiftKey) {
                    e.preventDefault()
                    this.el.closest("form").dispatchEvent(
                      new Event("submit", {bubbles: true, cancelable: true})
                    )
                    setTimeout(() => { this.el.value = "" }, 0)
                  }
                })
                // When the run pauses to ask a question, focus the input so the
                // user can answer immediately.
                this.handleEvent("focus-chat-input", () => {
                  setTimeout(() => this.el.focus(), 0)
                })
              }
            },

            PathInput: {
              mounted() {
                this.el.focus()
                this.el.setSelectionRange(this.el.value.length, this.el.value.length)
                this.el.addEventListener("keydown", e => {
                  if (e.key === "Tab") {
                    e.preventDefault()
                    this.pushEvent("tab_complete", {path: this.el.value})
                  }
                })
                this.handleEvent("tab_fill", ({value}) => {
                  this.el.value = value
                  // tell the server the new value so validation updates
                  this.pushEvent("modal_path_change", {path: value})
                })
              }
            },

            ImageInput: {
              mounted() {
                const bar = this.el
                const textarea = bar.querySelector("textarea")
                const fileInput = bar.querySelector("#image-file-input")

                const readAndPush = (file) => {
                  if (!file || !file.type.startsWith("image/")) return
                  const reader = new FileReader()
                  reader.onload = (e) => {
                    const [header, data] = e.target.result.split(",")
                    const type = header.match(/:(.*?);/)[1]
                    this.pushEvent("attach_image", {data, type})
                  }
                  reader.readAsDataURL(file)
                }

                if (textarea) {
                  textarea.addEventListener("paste", (e) => {
                    const items = Array.from(e.clipboardData?.items || [])
                    const imgItems = items.filter(i => i.type.startsWith("image/"))
                    if (imgItems.length > 0) {
                      e.preventDefault()
                      imgItems.forEach(i => readAndPush(i.getAsFile()))
                    }
                  })
                }

                bar.addEventListener("dragover", (e) => {
                  e.preventDefault()
                  bar.classList.add("drag-over")
                })

                bar.addEventListener("dragleave", (e) => {
                  if (!bar.contains(e.relatedTarget)) bar.classList.remove("drag-over")
                })

                bar.addEventListener("drop", (e) => {
                  e.preventDefault()
                  bar.classList.remove("drag-over")
                  Array.from(e.dataTransfer.files).forEach(readAndPush)
                })

                if (fileInput) {
                  fileInput.addEventListener("change", (e) => {
                    Array.from(e.target.files).forEach(readAndPush)
                    e.target.value = ""
                  })
                }
              }
            },

            // Resizable split-pane divider inside .chat-main. Mouse-drag on
            // .chat-divider updates --left-w / --right-w CSS variables on
            // the .chat-main element (this.el). Ratio persists in
            // localStorage. Clamped 20%–80%.
            SplitResize: {
              mounted() {
                const STORAGE_KEY = "ex_athena.split_ratio"
                const MIN = 0.20, MAX = 0.80
                const apply = (ratio) => {
                  const r = Math.max(MIN, Math.min(MAX, ratio))
                  this.el.style.setProperty("--left-w", `${r}fr`)
                  this.el.style.setProperty("--right-w", `${1 - r}fr`)
                  return r
                }

                const stored = parseFloat(localStorage.getItem(STORAGE_KEY))
                if (!isNaN(stored)) apply(stored)

                const divider = this.el.querySelector("#chat-divider")
                if (!divider) return

                divider.addEventListener("mousedown", (e) => {
                  e.preventDefault()
                  divider.classList.add("dragging")
                  document.body.style.cursor = "col-resize"
                  document.body.style.userSelect = "none"

                  const onMove = (ev) => {
                    const rect = this.el.getBoundingClientRect()
                    const ratio = (ev.clientX - rect.left) / rect.width
                    apply(ratio)
                  }

                  const onUp = () => {
                    divider.classList.remove("dragging")
                    document.body.style.cursor = ""
                    document.body.style.userSelect = ""
                    const left = parseFloat(getComputedStyle(this.el).getPropertyValue("--left-w"))
                    if (!isNaN(left)) localStorage.setItem(STORAGE_KEY, String(left))
                    document.removeEventListener("mousemove", onMove)
                    document.removeEventListener("mouseup", onUp)
                  }

                  document.addEventListener("mousemove", onMove)
                  document.addEventListener("mouseup", onUp)
                })

                // Left pane can request the right pane to scroll to a tool
                // entry by tool_call_id (e.g. clicking a one-liner).
                this.handleEvent("focus-detail", ({tool_call_id}) => {
                  const node = this.el.querySelector(
                    `.detail-entry[data-tool-call-id="${tool_call_id}"]`
                  )
                  if (!node) return
                  node.scrollIntoView({behavior: "smooth", block: "center"})
                  node.classList.add("detail-entry--focused")
                  setTimeout(() => node.classList.remove("detail-entry--focused"), 1200)
                })
              }
            }
          }

          // ── Bootstrap LiveSocket ───────────────────────────────────────────
          const csrfToken = document.querySelector("meta[name='csrf-token']").content
          const liveSocket = new LiveSocket("/live", Socket, {
            params: {_csrf_token: csrfToken},
            hooks: Hooks
          })
          liveSocket.connect()
          window.liveSocket = liveSocket
        </script>
      </head>
      <body style="height:100%;margin:0">
        {@inner_content}
      </body>
    </html>
    """
  end
end
