browser.tabs.onCreated.addListener(async (tab) => {
  const tabs = await browser.tabs.query({ windowId: tab.windowId });
  if (tabs.length > 1) {
    await browser.windows.create({ tabId: tab.id });
  }
});
