import assert from "node:assert/strict"
import {test} from "node:test"
import {ClipboardCopy} from "../../assets/js/hooks/clipboard_copy.js"

function mount(t, text) {
  const el = new EventTarget()
  el.dataset = text === undefined ? {} : {copyText: text}
  el.innerHTML = '<span class="hero-document-duplicate"></span>'
  Object.defineProperty(el, "textContent", {
    get: () => el.innerHTML.replace(/<[^>]*>/g, ""),
    set: value => { el.innerHTML = value },
  })
  const attrs = new Map([["aria-label", "Copy username"]])
  el.getAttribute = name => attrs.get(name) ?? null
  el.setAttribute = (name, value) => attrs.set(name, value)
  const events = new Map()
  const hook = {...ClipboardCopy, el, handleEvent: (name, fn) => events.set(name, fn)}
  hook.mounted()
  t.after(() => hook.destroyed?.())
  return {hook, el, events}
}

function clipboard(t, value) {
  const original = Object.getOwnPropertyDescriptor(navigator, "clipboard")
  Object.defineProperty(navigator, "clipboard", {configurable: true, value})
  t.after(() => {
    if (original) Object.defineProperty(navigator, "clipboard", original)
    else delete navigator.clipboard
  })
}

const settle = () => new Promise(resolve => setImmediate(resolve))

test("each button copies only its own current value and stops row clicks", async t => {
  const copied = []
  clipboard(t, {writeText: async text => copied.push(text)})
  const username = mount(t, "@cognocracy")
  const id = mount(t, "903489662")
  const click = new Event("click", {bubbles: true})
  const stop = t.mock.method(click, "stopPropagation")

  username.el.dispatchEvent(click)
  id.el.dispatchEvent(new Event("click"))
  await settle()
  assert.deepEqual(copied, ["@cognocracy", "903489662"])
  assert.equal(stop.mock.callCount(), 1)
  assert.equal(username.el.textContent, "copied ✓")

  username.el.dataset.copyText = "@updated"
  username.el.dispatchEvent(new Event("click"))
  await settle()
  assert.equal(copied.at(-1), "@updated")
  assert.equal(username.events.has("clipboard-copy"), false)
})

test("Enter and Space stay on the button without preventing native activation", t => {
  const {el} = mount(t, "903489662")
  for (const key of ["Enter", " ", "Tab"]) {
    const event = new Event("keydown", {bubbles: true, cancelable: true})
    event.key = key
    const stop = t.mock.method(event, "stopPropagation")
    el.dispatchEvent(event)
    assert.equal(stop.mock.callCount(), key === "Tab" ? 0 : 1)
    assert.equal(event.defaultPrevented, false)
  }
})

test("feedback restores the icon and accessible label after repeated copies", async t => {
  t.mock.timers.enable({apis: ["setTimeout"]})
  clipboard(t, {writeText: async () => {}})
  const {el} = mount(t, "903489662")
  const original = el.innerHTML
  el.dispatchEvent(new Event("click"))
  await settle()
  assert.equal(el.getAttribute("aria-label"), "copied ✓")
  t.mock.timers.tick(1000)
  el.dispatchEvent(new Event("click"))
  await settle()
  t.mock.timers.tick(1000)
  assert.equal(el.textContent, "copied ✓")
  t.mock.timers.tick(500)
  assert.equal(el.innerHTML, original)
  assert.equal(el.getAttribute("aria-label"), "Copy username")
})

for (const [name, api] of [
  ["permission denied", {writeText: async () => { throw new Error("denied") }}],
  ["clipboard unavailable", undefined],
]) {
  test(`${name} shows failure feedback`, async t => {
    clipboard(t, api)
    const {el} = mount(t, "903489662")
    el.dispatchEvent(new Event("click"))
    await settle()
    assert.equal(el.textContent, "copy failed")
    assert.equal(el.getAttribute("aria-label"), "copy failed")
  })
}

test("the existing log-copy server event still copies and restores its contents", async t => {
  t.mock.timers.enable({apis: ["setTimeout"]})
  const copied = []
  clipboard(t, {writeText: async text => copied.push(text)})
  const {el, events} = mount(t)
  const original = el.innerHTML
  events.get("clipboard-copy")({text: "release\nengine log"})
  await settle()
  assert.deepEqual(copied, ["release\nengine log"])
  assert.equal(el.textContent, "copied ✓")
  t.mock.timers.tick(1500)
  assert.equal(el.innerHTML, original)
})

test("unmount clears feedback timers and click listeners", async t => {
  t.mock.timers.enable({apis: ["setTimeout"]})
  const copied = []
  clipboard(t, {writeText: async text => copied.push(text)})
  const {hook, el} = mount(t, "903489662")
  el.dispatchEvent(new Event("click"))
  await settle()
  hook.destroyed()
  el.innerHTML = "removed"
  t.mock.timers.tick(1500)
  el.dispatchEvent(new Event("click"))
  assert.equal(el.innerHTML, "removed")
  assert.deepEqual(copied, ["903489662"])
})
