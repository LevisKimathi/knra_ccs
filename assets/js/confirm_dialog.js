// KNRA-styled confirmation dialog replacing the browser's window.confirm for
// every element with data-confirm (LiveView phx-click buttons, submit buttons
// and phoenix_html links alike).
//
//   <button data-confirm="Revoke API access for KenTrade?"
//           data-confirm-title="Revoke API Access"
//           data-confirm-button="Revoke"
//           data-confirm-variant="danger">   (danger | ok | primary, default primary)
//
// It listens on window in the capture phase, so it runs before phoenix_html and
// LiveView. On confirm it replays the click with data-confirm temporarily
// removed, so the original handlers run exactly as before.

const VARIANTS = {
  primary: "bg-brand text-white hover:bg-brand-dark",
  ok: "bg-ok text-white hover:brightness-110",
  danger: "bg-bad text-white hover:brightness-110",
}

const ICONS = {
  primary: "hero-question-mark-circle text-brand",
  ok: "hero-check-circle text-ok",
  danger: "hero-exclamation-triangle text-bad",
}

let replaying = false

function openDialog(trigger) {
  const variant = VARIANTS[trigger.dataset.confirmVariant] ? trigger.dataset.confirmVariant : "primary"
  const title = trigger.dataset.confirmTitle || "Please Confirm"
  const confirmLabel = trigger.dataset.confirmButton || "Confirm"
  const message = trigger.getAttribute("data-confirm")
  const previousFocus = document.activeElement

  const overlay = document.createElement("div")
  overlay.className = "fixed inset-0 z-[60] flex items-center justify-center bg-ink/45 px-4 backdrop-blur-[1px]"
  overlay.innerHTML = `
    <div role="alertdialog" aria-modal="true" aria-labelledby="knra-confirm-title" aria-describedby="knra-confirm-message"
         class="w-full max-w-md overflow-hidden rounded-md border border-line bg-white shadow-2xl">
      <div class="flex gap-3.5 px-6 pt-6 pb-5">
        <span class="${ICONS[variant]} mt-0.5 size-6 flex-none"></span>
        <div class="min-w-0">
          <h2 id="knra-confirm-title" class="text-base font-bold text-ink"></h2>
          <p id="knra-confirm-message" class="mt-1.5 text-sm leading-relaxed text-muted"></p>
        </div>
      </div>
      <div class="flex justify-end gap-2 border-t border-line-soft bg-panel px-6 py-3.5">
        <button type="button" data-action="cancel"
                class="rounded border border-[#c9d1d8] bg-white px-4 py-2 text-sm font-semibold text-ink hover:border-brand hover:text-brand">
          Cancel
        </button>
        <button type="button" data-action="confirm"
                class="rounded px-4 py-2 text-sm font-semibold ${VARIANTS[variant]}"></button>
      </div>
    </div>`

  // Text content, never HTML, so names in messages cannot inject markup
  overlay.querySelector("#knra-confirm-title").textContent = title
  overlay.querySelector("#knra-confirm-message").textContent = message
  overlay.querySelector('[data-action="confirm"]').textContent = confirmLabel

  const cancelBtn = overlay.querySelector('[data-action="cancel"]')
  const confirmBtn = overlay.querySelector('[data-action="confirm"]')

  const close = () => {
    overlay.remove()
    document.removeEventListener("keydown", onKey, true)
    if (previousFocus && previousFocus.isConnected) previousFocus.focus()
  }

  const confirm = () => {
    close()
    if (!trigger.isConnected) return
    replaying = true
    trigger.removeAttribute("data-confirm")
    try {
      trigger.click()
    } finally {
      trigger.setAttribute("data-confirm", message)
      replaying = false
    }
  }

  const onKey = e => {
    if (e.key === "Escape") {
      e.preventDefault()
      close()
    } else if (e.key === "Tab") {
      // keep focus inside the dialog
      e.preventDefault()
      ;(document.activeElement === confirmBtn ? cancelBtn : confirmBtn).focus()
    }
  }

  overlay.addEventListener("click", e => {
    if (e.target === overlay) close()
  })
  cancelBtn.addEventListener("click", close)
  confirmBtn.addEventListener("click", confirm)
  document.addEventListener("keydown", onKey, true)

  document.body.appendChild(overlay)
  // Destructive actions start on Cancel; others on the confirm button
  ;(variant === "danger" ? cancelBtn : confirmBtn).focus()
}

window.addEventListener(
  "click",
  e => {
    if (replaying) return
    const trigger = e.target.closest && e.target.closest("[data-confirm]")
    if (!trigger || trigger.disabled) return
    e.preventDefault()
    e.stopImmediatePropagation()
    openDialog(trigger)
  },
  true
)
