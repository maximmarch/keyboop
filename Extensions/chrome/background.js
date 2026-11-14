const HOST_NAME = "ru.keyboop.site_context";
const HEARTBEAT_ALARM = "keyboop-heartbeat";
const BROWSER_ID = "chrome";

const INTERNAL_PROTOCOLS = new Set([
  "chrome:",
  "chrome-extension:",
  "about:",
  "devtools:",
  "view-source:",
  "file:",
  "data:",
  "blob:",
  "javascript:",
  "edge:",
  "brave:",
  "arc:",
  "vivaldi:",
  "browser:",
  "chrome-search:",
  "chrome-untrusted:"
]);

let nativePort = null;

function extractDomainOnly(rawUrl) {
  if (!rawUrl || typeof rawUrl !== "string") {
    return { domain: null, internal: true };
  }
  let parsed;
  try {
    parsed = new URL(rawUrl);
  } catch {
    return { domain: null, internal: true };
  }
  if (INTERNAL_PROTOCOLS.has(parsed.protocol)) {
    return { domain: null, internal: true };
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    return { domain: null, internal: true };
  }
  const host = (parsed.hostname || "").trim().toLowerCase().replace(/\.+$/, "");
  if (!host) {
    return { domain: null, internal: true };
  }
  return { domain: host, internal: false };
}

async function saveSessionStatus(patch) {
  try {
    const prev = await chrome.storage.session.get({
      bridgeConnected: false,
      keyboopConnected: false,
      lastError: null,
      domain: null,
      internal: false,
      incognito: false,
      windowFocused: true,
      updatedAt: 0
    });
    await chrome.storage.session.set({
      ...prev,
      ...patch,
      updatedAt: Date.now()
    });
  } catch {
    // Ignore storage quota or shutdown errors
  }
}

function ensureNativePort() {
  if (nativePort) return nativePort;
  try {
    const port = chrome.runtime.connectNative(HOST_NAME);
    port.onMessage.addListener(async (msg) => {
      if (!msg || typeof msg !== "object") return;
      if (msg.type === "status") {
        await saveSessionStatus({
          bridgeConnected: true,
          keyboopConnected: Boolean(msg.keyboopRunning),
          lastError: null
        });
      } else if (msg.type === "query") {
        await publishActiveContext("host_query");
      }
    });
    port.onDisconnect.addListener(async () => {
      const err = chrome.runtime.lastError ? chrome.runtime.lastError.message : null;
      nativePort = null;
      await saveSessionStatus({
        bridgeConnected: false,
        keyboopConnected: false,
        lastError: err
      });
    });
    nativePort = port;
    saveSessionStatus({ bridgeConnected: true, lastError: null });
    return nativePort;
  } catch (err) {
    nativePort = null;
    saveSessionStatus({
      bridgeConnected: false,
      keyboopConnected: false,
      lastError: err ? String(err) : "connectNative failed"
    });
    return null;
  }
}

function postNative(payload) {
  const port = ensureNativePort();
  if (!port) return false;
  try {
    port.postMessage(payload);
    return true;
  } catch (err) {
    nativePort = null;
    saveSessionStatus({
      bridgeConnected: false,
      keyboopConnected: false,
      lastError: err ? String(err) : "postMessage failed"
    });
    return false;
  }
}

async function queryFocusedActiveTab() {
  try {
    const lastFocused = await chrome.windows.getLastFocused({ populate: false });
    if (!lastFocused || lastFocused.focused === false || lastFocused.id === chrome.windows.WINDOW_ID_NONE) {
      return { focused: false, tab: null, windowId: null };
    }
    const tabs = await chrome.tabs.query({ active: true, windowId: lastFocused.id });
    return { focused: true, tab: tabs[0] || null, windowId: lastFocused.id };
  } catch {
    return { focused: false, tab: null, windowId: null };
  }
}

async function publishActiveContext(reason, explicitTab = null) {
  let focused = true;
  let tab = explicitTab;
  let windowId = explicitTab ? explicitTab.windowId : null;

  if (!tab) {
    const res = await queryFocusedActiveTab();
    focused = res.focused;
    tab = res.tab;
    windowId = res.windowId;
  }

  if (!focused || !tab) {
    const payload = {
      type: "context",
      browser: BROWSER_ID,
      focused: false,
      windowId: windowId ?? null,
      tabId: null,
      domain: null,
      internal: false,
      incognito: false,
      reason,
      ts: Date.now()
    };
    await saveSessionStatus({
      windowFocused: false,
      domain: null,
      internal: false,
      incognito: false
    });
    postNative(payload);
    return;
  }

  const rawUrl = tab.pendingUrl || tab.url || "";
  const parsed = extractDomainOnly(rawUrl);
  const payload = {
    type: "context",
    browser: BROWSER_ID,
    focused: true,
    windowId: typeof tab.windowId === "number" ? tab.windowId : null,
    tabId: typeof tab.id === "number" ? tab.id : null,
    domain: parsed.domain,
    internal: parsed.internal,
    incognito: Boolean(tab.incognito),
    reason,
    ts: Date.now()
  };

  await saveSessionStatus({
    windowFocused: true,
    domain: parsed.domain,
    internal: parsed.internal,
    incognito: Boolean(tab.incognito)
  });

  postNative(payload);
}

async function ensureHeartbeatAlarm() {
  try {
    const existing = await chrome.alarms.get(HEARTBEAT_ALARM);
    if (!existing) {
      chrome.alarms.create(HEARTBEAT_ALARM, { periodInMinutes: 0.5 });
    }
  } catch {
    // Ignore
  }
}

// All event listeners MUST be registered synchronously at top level in MV3 service workers.
chrome.runtime.onInstalled.addListener(async () => {
  await ensureHeartbeatAlarm();
  await publishActiveContext("installed");
});

chrome.runtime.onStartup.addListener(async () => {
  await ensureHeartbeatAlarm();
  await publishActiveContext("startup");
});

chrome.alarms.onAlarm.addListener(async (alarm) => {
  if (alarm.name === HEARTBEAT_ALARM) {
    await publishActiveContext("heartbeat");
  }
});

chrome.tabs.onActivated.addListener(async (activeInfo) => {
  try {
    const win = await chrome.windows.get(activeInfo.windowId);
    if (!win || !win.focused) return;
    const tab = await chrome.tabs.get(activeInfo.tabId);
    await publishActiveContext("tab_activated", tab);
  } catch {
    await publishActiveContext("tab_activated");
  }
});

chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  if (!tab || !tab.active) return;
  if (typeof changeInfo.url !== "string" && changeInfo.status !== "complete") return;
  try {
    const win = await chrome.windows.get(tab.windowId);
    if (!win || !win.focused) return;
  } catch {
    return;
  }
  await publishActiveContext("tab_updated", tab);
});

chrome.tabs.onRemoved.addListener(async () => {
  await publishActiveContext("tab_removed");
});

chrome.windows.onFocusChanged.addListener(async (windowId) => {
  if (windowId === chrome.windows.WINDOW_ID_NONE) {
    await publishActiveContext("window_blur");
    return;
  }
  await publishActiveContext("window_focus");
});

chrome.windows.onRemoved.addListener(async () => {
  await publishActiveContext("window_removed");
});

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  (async () => {
    if (msg && msg.type === "getStatus") {
      await publishActiveContext("popup_refresh");
      const status = await chrome.storage.session.get({
        bridgeConnected: false,
        keyboopConnected: false,
        lastError: null,
        domain: null,
        internal: false,
        incognito: false,
        windowFocused: true,
        updatedAt: 0
      });
      sendResponse(status);
      return;
    }
    sendResponse({ ok: true });
  })();
  return true;
});

// Warm bridge immediately when service worker wakes up.
ensureHeartbeatAlarm();
ensureNativePort();
