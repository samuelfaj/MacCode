const hostName = 'io.remotecode.computer_use';
// What this file implements, reported by browser_status. Chrome keeps the manifest it first read
// when an extension is re-enabled rather than reloaded, so the manifest version can lag the code.
export const extensionVersion = '1.5.0';
const sessions = new Map();
let creatingTab = false;
const activatedDuringCreation = new Set();
let port;
let requests = Promise.resolve();
// The native host waits 35 s for an answer; answer first, even when a page never does.
const requestDeadlineMs = 30000;
const expired = Symbol('expired');

// Resolves to `expired` when the promise takes longer; the promise itself keeps running.
function within(promise, ms) {
  let timer;
  const limit = new Promise(resolve => { timer = setTimeout(() => resolve(expired), ms); });
  return Promise.race([promise, limit]).finally(() => clearTimeout(timer));
}

// Closing is browser-side work, but nothing may hold the request queue, so it is bounded too.
const release = session => within(handleRequest({operation: 'browser_close', session}).catch(() => {}), 5000);

// Runs in this extension's isolated world, without changing page attributes
// or exposing references to page scripts. The page cannot tell whether the user
// is looking at it (keepAwake makes it report "visible"), so the service worker
// checks tab selection before and after every call.
export function pageOperation(operation, args) {
  // executeScript drops thrown messages; with reportErrors the reason is returned instead.
  try {
    const elementVisible = element => {
      const rect = element.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) return false;
      for (let current = element; current; current = current.parentElement) {
        const style = getComputedStyle(current);
        if (style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) === 0) return false;
      }
      return true;
    };
    const elementCovered = element => {
      const rect = element.getBoundingClientRect();
      const top = document.elementFromPoint?.(rect.left + rect.width / 2, rect.top + rect.height / 2);
      if (!top || top === element || element.contains(top)) return false;
      // A shadow host is how elementFromPoint reports its own shadow content.
      return element.getRootNode?.().host !== top;
    };
    // Styled switches and checkboxes hide the real input and draw its label instead.
    const shown = element => (!elementVisible(element) && ['checkbox', 'radio'].includes(element.type)
      && Array.from(element.labels || []).find(elementVisible)) || element;
    const liveRegion = element => ['status', 'alert'].includes(element.getAttribute('role')) || element.getAttribute('aria-live') !== null;
    const elementSignature = element => ({
      role: element.getAttribute('role') || element.tagName.toLowerCase(),
      name: (element.getAttribute('aria-label') || element.labels?.[0]?.innerText || element.innerText || element.getAttribute('name') || '').trim().slice(0, 500),
      type: element.type || '',
      disabled: Boolean(element.disabled || element.getAttribute('aria-disabled') === 'true'),
      readOnly: Boolean(element.readOnly),
      href: element.getAttribute('href') || '',
      value: element.type === 'password' ? '' : String(element.value ?? '').slice(0, 1000)
    });
    if (operation === 'browser_act') {
      const snapshot = globalThis.__remoteCodeSnapshot;
      const entry = snapshot?.get(args.ref);
      const element = entry?.element;
      if (args.action !== 'scroll' || args.ref) {
        if (!entry || !element?.isConnected || !elementVisible(shown(element))
            || JSON.stringify(elementSignature(element)) !== JSON.stringify(entry.signature)) {
          throw new Error('stale_reference: take a new browser_snapshot.');
        }
      }
      if (element && (element.disabled || element.getAttribute('aria-disabled') === 'true')) {
        throw new Error('The element is disabled.');
      }
      if (element && args.action !== 'scroll' && elementCovered(shown(element))) throw new Error('element is covered');
      switch (args.action) {
        case 'click':
          element.click();
          break;
        case 'fill':
        case 'type': {
          const text = String(args.text ?? '');
          element.focus({preventScroll: true});
          if (element.tagName === 'SELECT') {
            if (args.action !== 'fill') throw new Error('Use fill to choose an option of a select.');
            const option = Array.from(element.options).find(item => item.value === text)
              || Array.from(element.options).find(item => item.text.trim() === text.trim());
            if (!option || option.disabled) throw new Error('No enabled option matches the given value or text.');
            element.selectedIndex = option.index;
          } else if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement || element instanceof HTMLSelectElement) {
            if (element.readOnly) throw new Error('The field is read-only.');
            const prototype = element instanceof HTMLInputElement ? HTMLInputElement.prototype
              : element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLSelectElement.prototype;
            const value = args.action === 'type' ? element.value + text : text;
            Object.getOwnPropertyDescriptor(prototype, 'value').set.call(element, value);
          } else if (element.isContentEditable) {
            element.textContent = (args.action === 'type' ? element.textContent : '') + text;
          } else {
            throw new Error('The element is not an editable field.');
          }
          element.dispatchEvent(new Event('input', {bubbles: true}));
          element.dispatchEvent(new Event('change', {bubbles: true}));
          break;
        }
        case 'scroll':
          (element || window).scrollBy({left: args.delta_x ?? 0, top: args.delta_y ?? 600, behavior: 'instant'});
          break;
        default:
          throw new Error('Unsupported browser action.');
      }
    }
    const token = crypto.randomUUID();
    const refs = new Map();
    let extraLive = 0;
    // A query narrows the snapshot before the cap, so a control past the first 200 can be found.
    const needles = String(args?.query ?? '').toLowerCase().split('|').map(part => part.trim()).filter(Boolean);
    const wanted = element => {
      if (!needles.length) return true;
      const {role, name, value} = elementSignature(element);
      const haystack = `${role}\n${name}\n${value}`.toLowerCase();
      return needles.some(needle => haystack.includes(needle));
    };
    const elements = Array.from(document.querySelectorAll('a,button,input,textarea,select,[role],[tabindex],[contenteditable],[aria-live]'))
      .filter(element => elementVisible(shown(element)) && wanted(element))
      .filter((element, index) => index < 200 || (liveRegion(element) && ++extraLive <= 20)).map((element, index) => {
        const ref = `${token}.${index}`;
        const signature = elementSignature(element);
        refs.set(ref, {element, signature});
        const item = {ref, role: signature.role, name: signature.name, value: signature.value};
        if (element.tagName === 'SELECT') {
          item.options = Array.from(element.options).slice(0, 50).map(option => ({value: option.value, text: option.text.trim()}));
          item.selected = element.value;
        }
        if (elementCovered(shown(element))) item.covered = true;
        if (liveRegion(element)) {
          const rect = element.getBoundingClientRect();
          if (rect.bottom <= 0 || rect.right <= 0 || rect.top >= globalThis.innerHeight || rect.left >= globalThis.innerWidth) item.offscreen = true;
        }
        return item;
      });
    globalThis.__remoteCodeSnapshot = refs;
    // The page text is the bulk of a snapshot; a caller that asked for specific controls does not need it.
    return {url: location.href, title: document.title, ready: document.readyState === 'complete',
      ...(needles.length ? {} : {text: (document.body?.innerText || '').slice(0, 16000)}), elements};
  } catch (error) {
    if (args?.reportErrors) return {error: String(error?.message || error)};
    throw error;
  }
}

// Runs in the page's MAIN world, the only world that sees the page's fetch/XHR.
// Counts requests started after this call; older ones (polling, streams) are ignored.
export function settleBegin() {
  const g = globalThis;
  if (!g.__remoteCodeNet) {
    const net = {seq: 0, marker: 0, open: new Set(), lastMutation: 0, observer: undefined};
    const track = () => {
      const id = ++net.seq;
      net.open.add(id);
      return () => net.open.delete(id);
    };
    const nativeFetch = g.fetch;
    if (typeof nativeFetch === 'function') {
      g.fetch = function (...fetchArgs) {
        const done = track();
        let promise;
        try { promise = nativeFetch.apply(this, fetchArgs); } catch (error) { done(); throw error; }
        promise.then(done, done);
        return promise;
      };
    }
    const nativeSend = g.XMLHttpRequest?.prototype?.send;
    if (nativeSend) {
      g.XMLHttpRequest.prototype.send = function (...sendArgs) {
        const done = track();
        this.addEventListener('loadend', done, {once: true});
        try { return nativeSend.apply(this, sendArgs); } catch (error) { done(); throw error; }
      };
    }
    g.__remoteCodeNet = net;
  }
  const net = g.__remoteCodeNet;
  net.marker = net.seq;
  net.lastMutation = performance.now();
  net.observer?.disconnect();
  net.observer = new MutationObserver(() => { net.lastMutation = performance.now(); });
  net.observer.observe(document, {subtree: true, childList: true, attributes: true, characterData: true});
}

export function settlePoll() {
  const net = globalThis.__remoteCodeNet;
  if (!net) return {pending: 0, idle: 1e9};
  let pending = 0;
  for (const id of net.open) if (id > net.marker) pending++;
  return {pending, idle: performance.now() - net.lastMutation};
}

const settleLimits = {pollMs: 50, quietMs: 150, idleCapMs: 2000, pendingCapMs: 10000};

// Polled from the service worker because timers in a background tab are throttled.
export async function settle(session, limits = settleLimits, ctx) {
  const start = Date.now();
  let lastPending = start;
  for (;;) {
    await new Promise(resolve => setTimeout(resolve, limits.pollMs));
    const tab = await ownedTab(session, ctx);
    let poll;
    try {
      [{result: poll}] = await executePageScript({target: {tabId: tab.id}, world: 'MAIN', func: settlePoll}, ctx);
    } catch {
      poll = {pending: 1, idle: 0};
    }
    const now = Date.now();
    const pending = (poll?.pending ?? 0) + (tab.status === 'loading' ? 1 : 0);
    if (pending > 0) lastPending = now;
    if (pending === 0 && (poll?.idle ?? 1e9) >= limits.quietMs) return {settle_ms: now - start, settled: true};
    if (now - start >= limits.pendingCapMs || (pending === 0 && now - lastPending >= limits.idleCapMs)) {
      return {settle_ms: now - start, settled: false};
    }
  }
}

async function groupTab(tab) {
  const [existing] = await chrome.tabGroups.query({windowId: tab.windowId, title: 'MacCode'});
  if (existing) {
    return chrome.tabs.group({groupId: existing.id, tabIds: [tab.id]});
  }
  const groupId = await chrome.tabs.group({tabIds: [tab.id], createProperties: {windowId: tab.windowId}});
  await chrome.tabGroups.update(groupId, {title: 'MacCode', color: 'grey', collapsed: true});
  return groupId;
}

// ctx belongs to one request: `aborted` stops a request that outlived its deadline from acting
// later, and `allowActive` is the caller's decision to act on a tab the user is using.
async function ownedTab(session, ctx) {
  if (ctx?.aborted) throw new Error('This request was abandoned after its deadline.');
  const entry = sessions.get(session);
  if (!entry) throw new Error('No owned tab. Use browser_open first.');
  const tab = await chrome.tabs.get(entry.tabId);
  if ((entry.takenOver || tab.active) && !ctx?.allowActive) {
    throw new Error('human_activity: the user selected this tab. Prefer browser_close, then browser_open for a new background tab. If the work must happen in this tab, retry with allow_while_user_active: true, unless the user said not to interrupt them.');
  }
  return tab;
}

// A hidden tab renders no frames, so dialogs and animated UI never appear, and Chrome freezes
// tabs in a collapsed group, so page scripts never return. Focus emulation keeps the owned tab
// rendering and unfrozen while it stays a background tab. The debugger stays attached (Chrome
// shows its yellow bar) until browser_close.
async function keepAwake(tabId) {
  let state = debuggerTabs.get(tabId);
  if (!state) {
    await chrome.debugger.attach({tabId}, '1.3');
    state = {};
    debuggerTabs.set(tabId, state);
  }
  if (!state.awake) {
    await chrome.debugger.sendCommand({tabId}, 'Emulation.setFocusEmulationEnabled', {enabled: true});
    // Page events report a JavaScript dialog, which blocks every script in the page.
    await chrome.debugger.sendCommand({tabId}, 'Page.enable');
    state.awake = true;
  }
  return state;
}

function validURL(raw) {
  const url = new URL(raw);
  if (!['http:', 'https:'].includes(url.protocol)) throw new Error('Only HTTP and HTTPS URLs are supported.');
  return url.href;
}

export async function handleRequest(request, ctx = {}) {
  const {operation, session, arguments: args = {}} = request;
  if (typeof session !== 'string' || !/^[a-f0-9-]{36}$/i.test(session)) throw new Error('Invalid browser session.');
  if (args.allow_while_user_active !== undefined && typeof args.allow_while_user_active !== 'boolean') throw new Error('allow_while_user_active must be a boolean.');
  if (args.query !== undefined && typeof args.query !== 'string') throw new Error('query must be a string.');
  ctx.allowActive = args.allow_while_user_active === true;
  if (operation === 'browser_status') return {connected: true, mode: 'current_chrome_profile', hasTab: sessions.has(session), version: extensionVersion};
  if (operation === 'browser_close') {
    const entry = sessions.get(session);
    if (!entry) return {closed: false, released: false};
    if (debuggerTabs.has(entry.tabId)) {
      await chrome.debugger.detach({tabId: entry.tabId});
      debuggerTabs.delete(entry.tabId);
    }
    let tab;
    try { tab = await chrome.tabs.get(entry.tabId); }
    catch {
      sessions.delete(session);
      return {closed: false, released: true};
    }
    if (entry.takenOver || tab.active) {
      sessions.delete(session);
      return {closed: false, released: true};
    }
    sessions.delete(session);
    try {
      await chrome.tabs.remove(entry.tabId);
      return {closed: true, released: true};
    } catch {
      return {closed: false, released: true};
    }
  }
  if (operation === 'browser_open') {
    const url = validURL(args.url);
    // MacCode keeps one tab per session: opening again navigates that tab while it is still ours.
    // A tab the user selected refuses here like every other call, unless the caller escalates.
    if (sessions.has(session)) {
      const tab = await ownedTab(session, ctx);
      await chrome.tabs.update(tab.id, {url});
      return {url, loading: true, next: 'Use browser_snapshot to read the page after navigation.'};
    }
    if (sessions.size >= 32) throw new Error('Close an existing MacCode browser session first.');
    const window = await chrome.windows.getLastFocused({windowTypes: ['normal']});
    if (window.incognito) throw new Error('Open a regular Chrome window in the profile you want to use.');
    // A new tab is navigated only as part of its creation, while it is still inactive.
    activatedDuringCreation.clear();
    creatingTab = true;
    let tab;
    try { tab = await chrome.tabs.create({windowId: window.id, url, active: false}); }
    finally { creatingTab = false; }
    sessions.set(session, {tabId: tab.id, takenOver: tab.active || activatedDuringCreation.has(tab.id)});
    activatedDuringCreation.clear();
    if (!tab.active && !sessions.get(session)?.takenOver) {
      await chrome.tabs.update(tab.id, {muted: true});
      // Wake the tab before it joins the collapsed group. The next call retries a failed attach.
      try { await keepAwake(tab.id); } catch {}
      // Grouping is cosmetic; a failure must not fail browser_open.
      try { sessions.get(session).groupId = await groupTab(tab); } catch {}
    }
    return {url, loading: true, next: 'Use browser_snapshot to read the page after navigation.'};
  }
  if (extendedTools.includes(operation)) return extendedRequest(operation, session, args, ctx);
  if (!['browser_snapshot', 'browser_act'].includes(operation)) throw new Error('Unknown browser operation.');
  if (operation === 'browser_act') {
    if (!['click', 'fill', 'type', 'scroll'].includes(args.action)) throw new Error('Unsupported browser action.');
    if (args.action !== 'scroll' && typeof args.ref !== 'string') throw new Error('An element ref from browser_snapshot is required.');
    if (['delta_x', 'delta_y'].some(key => args[key] !== undefined && !Number.isFinite(args[key]))) throw new Error('Scroll distances must be finite.');
  }
  let tab = await ownedTab(session, ctx);
  // Snapshots and DOM actions do not need the debugger; without it the deadline still bounds the call.
  try { await keepAwake(tab.id); } catch {}
  if (debuggerTabs.get(tab.id)?.dialog) return {dialog: debuggerTabs.get(tab.id).dialog};
  if (tab.status === 'loading') {
    if (operation === 'browser_act') throw new Error('The page is still loading. Take a browser_snapshot again shortly.');
    const deadline = Date.now() + 10000;
    while (tab.status === 'loading' && Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 50));
      tab = await ownedTab(session, ctx);
    }
    if (tab.status === 'loading') throw new Error('The page did not finish loading within 10 seconds.');
  }
  if (new URL(tab.url).protocol !== 'about:') validURL(tab.url);
  const run = (world, func, funcArgs) => executePageScript({target: {tabId: tab.id}, world, func, args: funcArgs}, ctx);
  if (operation === 'browser_act') await run('MAIN', settleBegin);
  let results = await run('ISOLATED', pageOperation, [operation, operation === 'browser_act' ? {...args, reportErrors: true} : args]);
  let settled = {};
  if (operation === 'browser_act') {
    if (results[0]?.result?.error) throw new Error(results[0].result.error);
    if (!results[0]?.result) throw new Error('The page did not return a snapshot.');
    settled = await settle(session, settleLimits, ctx);
    // Refs from the pre-settle snapshot are replaced by one that shows the settled page.
    results = await run('ISOLATED', pageOperation, ['browser_snapshot', {}]);
  }
  // Selection during the call withholds the result: it may show what the user is now doing.
  await ownedTab(session, ctx);
  if (!results[0]?.result) throw new Error('The page did not return a snapshot.');
  return {...results[0].result, ...settled};
}

async function executePageScript(options, ctx) {
  if (ctx?.aborted) throw new Error('This request was abandoned after its deadline.');
  const tab = await chrome.tabs.get(options.target.tabId);
  if (new URL(tab.url).protocol !== 'about:') return chrome.scripting.executeScript(options);
  // chrome.scripting cannot inject into about: pages; evaluate through the debugger instead.
  const source = {tabId: tab.id};
  const state = await keepAwake(tab.id);
  const command = (method, params = {}) => chrome.debugger.sendCommand(source, method, params);
  await command('Page.enable');
  const {frameTree} = await command('Page.getFrameTree');
  let contextId;
  if (options.world !== 'MAIN') {
    ({executionContextId: contextId} = await command('Page.createIsolatedWorld', {frameId: frameTree.frame.id, worldName: 'remote-code-about'}));
    state.contextId = contextId;
  }
  const result = await command('Runtime.evaluate', {
    expression: `(${options.func.toString()})(...${JSON.stringify(options.args || [])})`,
    ...(contextId ? {contextId} : {}), returnByValue: true
  });
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
  return [{result: result.result?.value}];
}

// Per-tab debugger state, attached by keepAwake for as long as the tab is owned.
// Dialogs opened while detached are not observable.
const debuggerTabs = new Map();
const dialogWaiters = new Set();
chrome.debugger.onEvent.addListener((source, method, params) => {
  const state = debuggerTabs.get(source.tabId);
  if (!state) return;
  if (method === 'Page.javascriptDialogOpening') {
    state.dialog = params;
    for (const waiter of dialogWaiters) if (waiter.tabId === source.tabId) waiter.opened();
  }
  if (method === 'Page.javascriptDialogClosed') state.dialog = undefined;
  if (method === 'Runtime.executionContextCreated') {
    const context = params.context;
    if (context.origin === `chrome-extension://${chrome.runtime.id}` || context.name === 'remote-code-about') state.contextId = context.id;
  }
});
chrome.debugger.onDetach.addListener(source => debuggerTabs.delete(source.tabId));

const extendedTools = ['browser_navigate', 'browser_click', 'browser_type', 'browser_pointer',
  'browser_dialog', 'browser_set_input_files', 'browser_download', 'page'];

// Runs in the same isolated world as snapshot references.
export function resolveTarget(args) {
  // executeScript drops thrown messages; with reportErrors the reason is returned instead.
  try {
    const element = args.ref ? globalThis.__remoteCodeSnapshot?.get(args.ref)?.element
      : args.css_selector ? document.querySelector(args.css_selector) : undefined;
    if ((args.ref || args.css_selector) && !element?.isConnected) throw new Error('stale_reference: take a new browser_snapshot.');
    if (!element) {
      if (!Number.isFinite(args.x) || !Number.isFinite(args.y) || args.x < 0 || args.y < 0 || args.x >= innerWidth || args.y >= innerHeight) throw new Error('A ref or finite viewport x,y is required.');
      return {x: args.x, y: args.y};
    }
    const entry = args.ref && globalThis.__remoteCodeSnapshot.get(args.ref);
    const signature = {
      role: element.getAttribute('role') || element.tagName.toLowerCase(),
      name: (element.getAttribute('aria-label') || element.labels?.[0]?.innerText || element.innerText || element.getAttribute('name') || '').trim().slice(0, 500),
      type: element.type || '', disabled: Boolean(element.disabled || element.getAttribute('aria-disabled') === 'true'),
      readOnly: Boolean(element.readOnly), href: element.getAttribute('href') || '',
      value: element.type === 'password' ? '' : String(element.value ?? '').slice(0, 1000)
    };
    if (entry && JSON.stringify(signature) !== JSON.stringify(entry.signature)) throw new Error('stale_reference: take a new browser_snapshot.');
    if (element.disabled || element.getAttribute('aria-disabled') === 'true') throw new Error('The element is disabled.');
    element.scrollIntoView({block: 'center', inline: 'nearest', behavior: 'instant'});
    const rect = element.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) throw new Error('The element is not visible.');
    const x = rect.left + rect.width / 2, y = rect.top + rect.height / 2;
    const top = document.elementFromPoint(x, y);
    if (top && top !== element && !element.contains(top) && element.getRootNode()?.host !== top) throw new Error('element is covered');
    if (args.focus) element.focus({preventScroll: true});
    return {x, y, href: element.href};
  } catch (error) {
    if (args.reportErrors) return {error: String(error?.message || error)};
    throw error;
  }
}

export function pageQuery(args) {
  if (args.action === 'get_text') return (args.css_selector ? document.querySelector(args.css_selector) : document.body)?.innerText || '';
  return Array.from(document.querySelectorAll(args.css_selector)).slice(0, 200).map(element => ({
    tag: element.tagName.toLowerCase(), text: element.innerText,
    attributes: Object.fromEntries((args.attributes || []).map(name => [name, element.getAttribute(name)]))
  }));
}

async function extendedRequest(operation, session, args, ctx) {
  let tab = await ownedTab(session, ctx);
  const run = async (func, values, world = 'ISOLATED') => {
    await ownedTab(session, ctx);
    const result = await executePageScript({target: {tabId: tab.id}, world, func, args: values}, ctx);
    if (!result[0] || result[0].error) throw new Error('Page script failed.');
    await ownedTab(session, ctx);
    return result[0].result;
  };
  const allow = ctx.allowActive ? {allow_while_user_active: true} : {};
  const snapshot = async extra => ({...await handleRequest({operation: 'browser_snapshot', session, arguments: allow}, ctx), ...extra});
  if (operation === 'browser_navigate') {
    if (typeof args.url !== 'string') throw new Error('url must be a string.');
    const url = new URL(args.url);
    if (!['http:', 'https:', 'about:'].includes(url.protocol)) throw new Error('Only HTTP, HTTPS and about URLs are supported.');
    await run(() => { globalThis.__remoteCodeSnapshot = undefined; }, []);
    await ownedTab(session, ctx);
    await chrome.tabs.update(tab.id, {url: url.href});
    await settle(session, settleLimits, ctx);
    return snapshot({});
  }
  if (operation === 'page') {
    if (!['execute_javascript', 'get_text', 'query_dom', 'click_element', 'insert_text', 'type_keystrokes'].includes(args.action)) throw new Error('Unsupported page action.');
    args = {...args, css_selector: args.css_selector || args.selector};
    if (args.action === 'get_text' || args.action === 'query_dom') {
      if (args.action === 'query_dom' && typeof args.css_selector !== 'string') throw new Error('css_selector is required.');
      if (args.attributes !== undefined && (!Array.isArray(args.attributes) || args.attributes.some(a => typeof a !== 'string'))) throw new Error('attributes must be strings.');
      return {result: await run(pageQuery, [args])};
    }
    if (args.action !== 'execute_javascript') return extendedRequest(args.action === 'click_element' ? 'browser_click' : 'browser_type', session,
      {...args, mode: args.action === 'type_keystrokes' ? 'keystrokes' : 'insert_text'}, ctx);
    if (typeof args.javascript !== 'string') throw new Error('javascript is required.');
  }
  if (operation === 'browser_download') {
    if (typeof args.ref !== 'string' || typeof args.directory !== 'string' || !args.directory.startsWith('/')) throw new Error('ref and absolute directory are required.');
    const target = await run(resolveTarget, [args]);
    const url = validURL(target.href);
    await ownedTab(session, ctx);
    const id = await chrome.downloads.download({url, filename: `MacCode/${crypto.randomUUID()}`, saveAs: false, conflictAction: 'uniquify'});
    const deadline = Date.now() + 10000;
    for (;;) {
      await ownedTab(session, ctx);
      const [item] = await chrome.downloads.search({id});
      if (item?.state === 'complete') {
        try { return await snapshot({download_path: item.filename}); }
        catch (error) { throw new Error(`${error.message}; completed download remains at ${item.filename}`); }
      }
      if (item?.state === 'interrupted') throw new Error(`Download interrupted: ${item.error}`);
      if (Date.now() >= deadline) {
        await chrome.downloads.cancel(id);
        throw new Error('Download timed out and was cancelled.');
      }
      await new Promise(resolve => setTimeout(resolve, 100));
    }
  }
  if (operation === 'browser_type' && (typeof args.text !== 'string' || !['insert_text', 'keystrokes'].includes(args.mode ?? 'insert_text'))) throw new Error('text and valid mode are required.');
  if (operation === 'browser_dialog' && !['inspect', 'accept', 'dismiss'].includes(args.action)) throw new Error('Unsupported dialog action.');
  if (operation === 'browser_dialog' && args.prompt_text !== undefined && typeof args.prompt_text !== 'string') throw new Error('prompt_text must be a string.');
  if (operation === 'browser_set_input_files' && (typeof args.ref !== 'string' || !Array.isArray(args.paths) || args.paths.some(p => typeof p !== 'string' || !p.startsWith('/') || p.includes('\0')))) throw new Error('ref and absolute paths are required.');
  if (operation === 'browser_pointer' && !['hover', 'right_click', 'double_click', 'scroll', 'drag'].includes(args.action)) throw new Error('Unsupported pointer action.');
  const source = {tabId: tab.id};
  const state = await keepAwake(tab.id);
  if (state.dialog && operation !== 'browser_dialog') return {dialog: state.dialog};
  const command = async (method, params = {}) => {
    await ownedTab(session, ctx);
    const result = await chrome.debugger.sendCommand(source, method, params);
    await ownedTab(session, ctx);
    return result;
  };
  // The browser handles a dialog by itself; the page answers nothing while one is open.
  if (operation !== 'browser_dialog') await command('Runtime.enable');
  if (operation === 'browser_dialog') {
    if (args.action === 'inspect') return {dialog: state.dialog || null};
    await command('Page.handleJavaScriptDialog', {accept: args.action === 'accept', ...(args.prompt_text === undefined ? {} : {promptText: args.prompt_text})});
    state.dialog = undefined;
  } else if (operation === 'browser_set_input_files') {
    if (!state.contextId) throw new Error('Snapshot execution context unavailable. Take a browser_snapshot first.');
    const result = await command('Runtime.evaluate', {contextId: state.contextId,
      expression: `(() => { const element = globalThis.__remoteCodeSnapshot?.get(${JSON.stringify(args.ref)})?.element; return element?.isConnected ? element : null; })()`, returnByValue: false});
    if (!result.result?.objectId || result.exceptionDetails) throw new Error('stale_reference: take a new browser_snapshot.');
    const objectId = result.result.objectId;
    try {
      const {node} = await command('DOM.describeNode', {objectId});
      if (node.attributes?.includes('disabled')) throw new Error('The element is disabled.');
      if (node.nodeName !== 'INPUT' || !node.attributes?.some((value, index, all) => value === 'type' && all[index + 1] === 'file')) throw new Error('Reference is not a file input.');
      await command('DOM.setFileInputFiles', {backendNodeId: node.backendNodeId, files: args.paths});
    } finally { await command('Runtime.releaseObject', {objectId}); }
  } else if (operation === 'page') {
    const result = await command('Runtime.evaluate', {expression: args.javascript, returnByValue: true, awaitPromise: false});
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.text || 'JavaScript failed.');
    if (state.dialog) return {dialog: state.dialog};
    await settle(session, settleLimits, ctx);
    return snapshot({result: result.result?.value ?? null});
  } else {
    const point = async values => {
      const point = await run(resolveTarget, [{...values, reportErrors: true}]);
      if (point?.error) throw new Error(point.error);
      if (!Number.isFinite(point?.x) || !Number.isFinite(point?.y) || point.x < 0 || point.y < 0) throw new Error('A ref or finite viewport x,y is required.');
      return {x: point.x, y: point.y};
    };
    const trustedInput = (reset = false) => run(() => {
      if (!globalThis.__remoteCodeInputListenerInstalled) {
        for (const type of ['mousedown', 'wheel', 'keydown'])
          window.addEventListener(type, () => { globalThis.__remoteCodeInputSeen = (globalThis.__remoteCodeInputSeen || 0) + 1; }, true);
        globalThis.__remoteCodeInputListenerInstalled = true;
      }
      if (reset) globalThis.__remoteCodeInputSeen = 0;
      return globalThis.__remoteCodeInputSeen || 0;
    }, [], 'MAIN');
    const mouse = (type, position, extra = {}) => command('Input.dispatchMouseEvent', {type, ...position, ...extra});
    const click = async (position, button, count) => {
      if (!['left', 'right', 'middle'].includes(button) || ![1, 2, 3].includes(count)) throw new Error('Invalid button or click_count.');
      for (let n = 1; n <= count; n++) {
        await mouse('mouseMoved', position);
        await mouse('mousePressed', position, {button, clickCount: n});
        await mouse('mouseReleased', position, {button, clickCount: n});
      }
    };
    const checksTrustedInput = operation === 'browser_type' ? (args.mode ?? 'insert_text') === 'keystrokes' : !(operation === 'browser_pointer' && args.action === 'hover');
    if (checksTrustedInput) await trustedInput(true);
    if (operation === 'browser_type') {
      if (args.ref || args.css_selector) await point({...args, focus: true});
      if ((args.mode ?? 'insert_text') === 'insert_text') await command('Input.insertText', {text: args.text});
      else for (const key of args.text) {
        await command('Input.dispatchKeyEvent', {type: 'keyDown', key, text: key});
        await command('Input.dispatchKeyEvent', {type: 'keyUp', key});
      }
    } else {
      const position = await point(args);
      const destination = operation === 'browser_pointer' && args.action === 'drag' ? await point({ref: args.to_ref, x: args.to_x, y: args.to_y}) : null;
      if (operation === 'browser_click') await click(position, args.button ?? 'left', args.click_count ?? 1);
      else if (args.action === 'hover') await mouse('mouseMoved', position);
      else if (args.action === 'right_click' || args.action === 'double_click') await click(position, args.action === 'right_click' ? 'right' : 'left', args.action === 'double_click' ? 2 : 1);
      else if (args.action === 'scroll') {
        const deltaX = args.delta_x ?? 0, deltaY = args.delta_y ?? 600;
        if (!Number.isFinite(deltaX) || !Number.isFinite(deltaY)) throw new Error('Scroll distances must be finite.');
        await mouse('mouseWheel', position, {deltaX, deltaY});
      } else {
        await mouse('mousePressed', position, {button: 'left', clickCount: 1});
        try { await mouse('mouseMoved', destination, {button: 'left', buttons: 1}); }
        finally { await mouse('mouseReleased', destination, {button: 'left', clickCount: 1}); }
      }
    }
    if (checksTrustedInput && await trustedInput() === 0) throw new Error('trusted_input_not_delivered: Chrome dropped trusted input to this tab; use browser_act (click/fill/type) or browser_type mode insert_text.');
  }
  if (state.dialog) return {dialog: state.dialog};
  await settle(session, settleLimits, ctx);
  return snapshot({});
}

// One page that never answers (frozen, discarded or stuck in script) must not hold the queue
// and starve every later request. The abandoned request is aborted so it cannot act when the
// page wakes, and its tab is closed because an injected script may already be queued there.
// A JavaScript dialog also blocks the page, but only until browser_dialog handles it, so the
// call that opened it reports the dialog and keeps the tab.
export async function runRequest(request, deadlineMs = requestDeadlineMs, dialogGraceMs = 250) {
  const ctx = {aborted: false};
  const blocked = Symbol('blocked');
  const tabId = sessions.get(request.session)?.tabId;
  const waiter = {tabId};
  const dialog = new Promise(resolve => { waiter.opened = () => resolve(blocked); });
  dialogWaiters.add(waiter);
  const work = handleRequest(request, ctx);
  work.catch(() => {});
  let outcome;
  try {
    outcome = await Promise.race([within(work, deadlineMs), dialog]);
    // Input that was only dispatched may still return by itself; give it a moment.
    if (outcome === blocked && await within(work, dialogGraceMs) !== expired) outcome = await work;
    if (outcome !== expired && outcome !== blocked) return outcome;
  } finally {
    dialogWaiters.delete(waiter);
    ctx.aborted = true;
  }
  if (outcome === blocked && debuggerTabs.get(tabId)?.dialog) return {dialog: debuggerTabs.get(tabId).dialog};
  await release(request.session);
  throw new Error(`tab_unresponsive: the page did not answer within ${deadlineMs / 1000} seconds, so its tab was released. Use browser_open again.`);
}

function badge(text, title) {
  chrome.action.setBadgeText({text});
  chrome.action.setTitle({title});
}

function disconnected(connection, error) {
  if (port !== connection) return;
  port = undefined;
  badge('OFF', error || chrome.i18n.getMessage('disconnectedTitle'));
  // Let any running request settle before releasing session handles.
  requests = requests.then(async () => {
    for (const session of [...sessions.keys()]) await release(session);
  });
}

function connect() {
  if (port) return;
  const connection = chrome.runtime.connectNative(hostName);
  const connectedAt = Date.now();
  port = connection;
  badge('ON', chrome.i18n.getMessage('connectedTitle'));
  connection.onMessage.addListener(request => {
    requests = requests.then(async () => {
      if (port !== connection) return;
      let response;
      try { response = {id: request.id, ok: true, ...(await runRequest(request))}; }
      catch (error) { response = {id: request.id, ok: false, error: String(error.message || error)}; }
      if (port === connection) connection.postMessage(response);
    }).catch(() => {});
  });
  connection.onDisconnect.addListener(() => {
    const error = chrome.runtime.lastError?.message;
    disconnected(connection, error);
    // A connection that fails at once is retried by the alarm, not in a tight loop.
    if (Date.now() - connectedAt >= 5000) setTimeout(connect, 1000);
  });
}

chrome.tabs.onActivated.addListener(({tabId}) => {
  if (creatingTab) activatedDuringCreation.add(tabId);
  for (const entry of sessions.values()) if (entry.tabId === tabId) entry.takenOver = true;
});
chrome.tabs.onRemoved.addListener(tabId => {
  for (const [session, entry] of sessions) if (entry.tabId === tabId) sessions.delete(session);
});
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.groupId === undefined) return;
  for (const entry of sessions.values()) {
    if (entry.tabId === tabId && entry.groupId !== undefined && changeInfo.groupId !== entry.groupId) {
      entry.takenOver = true;
    }
  }
});
chrome.action.onClicked.addListener(() => {
  if (!port) connect();
});
chrome.runtime.onInstalled.addListener(connect);
chrome.runtime.onStartup.addListener(connect);
chrome.alarms.create('keep-connected', {periodInMinutes: 0.5});
chrome.alarms.onAlarm.addListener(alarm => {
  if (alarm.name === 'keep-connected') connect();
});
connect();
