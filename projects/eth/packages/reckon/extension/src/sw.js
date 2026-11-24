// The extension's service worker: it only opens the page. Admission runs in the page's worker, and apps are shown by
// the sandbox loader (docs/browser-extension.md), so nothing is served from here.
chrome.action.onClicked.addListener(() => chrome.tabs.create({ url: chrome.runtime.getURL('page.html') }));

// The page's fence (page.js) is a session rule named by its tab's id: taken down with the tab.
chrome.tabs.onRemoved.addListener((tabId) => { chrome.declarativeNetRequest.updateSessionRules({ removeRuleIds: [tabId] }).catch(() => {}); });
