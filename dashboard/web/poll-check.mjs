import assert from 'node:assert/strict'
import fs from 'node:fs'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import ts from 'typescript'
import { JSDOM } from 'jsdom'
import React, { act } from 'react'
import { createRoot } from 'react-dom/client'

const require = createRequire(import.meta.url)
const dom = new JSDOM('<div id="root"></div>', { pretendToBeVisual: true })
globalThis.window = dom.window
globalThis.document = dom.window.document
globalThis.IS_REACT_ACT_ENVIRONMENT = true
function loadHook(name) {
  const source = fs.readFileSync(new URL(`./src/lib/${name}.ts`, import.meta.url), 'utf8')
  const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText
    .replace('from "react"', `from ${JSON.stringify(pathToFileURL(require.resolve('react')).href)}`)
    .replace('from "./use-page-visible"', () => `from ${JSON.stringify(loadHook('use-page-visible'))}`)
  return `data:text/javascript;base64,${Buffer.from(code).toString('base64')}`
}
const { usePoll } = await import(loadHook('use-poll'))

let state
let calls = 0
const pending = []
const fetcher = () => {
  calls++
  return new Promise(resolve => pending.push(resolve))
}
function Harness({ enabled }) {
  state = usePoll(fetcher, 0, enabled)
  return null
}
const root = createRoot(document.getElementById('root'))
try {
  await act(async () => root.render(React.createElement(Harness, { enabled: true })))
  assert.equal(calls, 1)
  await act(async () => { void state.refresh(); void state.refresh() })
  assert.equal(calls, 1, 'manual refresh shares an active request')
  await act(async () => pending.shift()('first'))
  assert.equal(state.data, 'first')
  assert.equal(state.loading, false)
  await act(async () => { void state.refresh() })
  assert.equal(state.loading, true)
  await act(async () => root.render(React.createElement(Harness, { enabled: false })))
  await act(async () => pending.shift()('stale'))
  assert.equal(state.data, 'first', 'disabled generation cannot overwrite data')
  assert.equal(state.loading, false)
  await act(async () => root.render(React.createElement(Harness, { enabled: true })))
  await act(async () => pending.shift()('current'))
  assert.equal(state.data, 'current')
  assert.equal(calls, 3)
  await act(async () => {
    Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'hidden' })
    document.dispatchEvent(new window.Event('visibilitychange'))
  })
  assert.equal(state.loading, false)
  assert.equal(calls, 3)
  await act(async () => {
    Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'visible' })
    document.dispatchEvent(new window.Event('visibilitychange'))
  })
  assert.equal(calls, 4, 'returning to the page refreshes stale data')
  await act(async () => pending.shift()('visible'))
  console.log('poll-check ok: overlapping refreshes, loading state, and stale responses')
} finally {
  await act(async () => root.unmount())
  dom.window.close()
}
