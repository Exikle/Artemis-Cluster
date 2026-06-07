# Skill: Playwright Browser Automation

Use Playwright from WSL to automate a browser UI — scrape data, fill forms, trigger actions, or verify a running web app when no API exists or the API endpoints are unknown.

> **API-first rule**: If the app has an API, use `curl` directly. Only reach for Playwright when the UI is the only interface, when you need to discover what API calls the UI makes, or when you need to take screenshots for verification.

---

## Step 1 — Setup

Playwright runs as Node.js scripts from WSL. Scripts connect to an **already-running Chrome instance on Windows** via the Chrome DevTools Protocol (CDP). Playwright cannot launch Windows Chrome directly from WSL — the pipe mode fails.

**Start Chrome on Windows** (run once per session, in a PowerShell terminal):

```powershell
& "C:\Program Files\Google\Chrome\Application\chrome.exe" `
  --remote-debugging-port=9222 `
  --user-data-dir="$env:TEMP\chrome-debug"
```

Verify it's reachable from WSL:

```bash
curl -s http://localhost:9222/json/version | jq '.Browser'
```

**Install Playwright in a temp workspace:**

```bash
mkdir -p /tmp/pw-work && cd /tmp/pw-work
npm install playwright
```

---

## Step 2 — Script Template

All scripts use ESM (`.mjs`). Connect via CDP, never launch:

```js
import { chromium } from "playwright";

const browser = await chromium.connectOverCDP("http://localhost:9222");
const context = browser.contexts()[0];
const page = context.pages()[0];

// Navigate or work with the existing page
await page.goto("https://example.dcunha.io");
await page.waitForLoadState("networkidle");

// ... your automation here ...

await browser.disconnect(); // disconnect, do NOT call browser.close()
```

> **`disconnect()` not `close()`** — `browser.close()` kills the Chrome process. `disconnect()` detaches cleanly and leaves the browser running.

---

## Step 3 — Common Patterns

### Fill a form field

```js
await page.locator('input[name="username"]').fill("myvalue");
```

### Click a button

```js
await page.locator('button:has-text("Save")').click();
```

### Select all text in a field and replace it

```js
// page.keyboard.selectAll() does NOT exist in Playwright
await page.locator("input#myfield").click({ clickCount: 3 }); // triple-click selects all
await page.keyboard.type("new value");
// OR: just use .fill() which replaces the value entirely
await page.locator("input#myfield").fill("new value");
```

### Intercept network requests (discover API endpoints)

```js
page.on("request", (req) => {
    if (req.url().includes("/api/")) {
        console.log(req.method(), req.url(), req.postData());
    }
});
page.on("response", async (res) => {
    if (res.url().includes("/api/")) {
        console.log(res.status(), res.url());
    }
});
// Then trigger the UI action you want to observe
await page.locator('button:has-text("Save")').click();
await page.waitForTimeout(2000);
```

Use this to discover real API endpoints, then switch to direct `curl` calls.

### Screenshot for verification

```js
await page.screenshot({ path: "/tmp/pw-work/screenshot.png", fullPage: true });
```

### Wait for a UI state

```js
await page.waitForSelector('[data-testid="success"]');
await page.waitForLoadState("networkidle");
await page.waitForTimeout(1000); // last resort — prefer explicit waits
```

### Handle dropdowns / selects

```js
await page.locator("select#quality").selectOption("1080p");
// For custom UI dropdowns (not native <select>):
await page.locator('[role="combobox"]').click();
await page.locator('[role="option"]:has-text("1080p")').click();
```

---

## Step 4 — Run the Script

```bash
cd /tmp/pw-work
node my-script.mjs
```

If there are import errors, check that `playwright` (not `@playwright/test`) is installed:

```bash
ls node_modules | grep playwright
# should show: playwright  (the standalone package, not @playwright/test)
```

---

## Common Issues / Gotchas

| Problem                                     | Cause                                             | Fix                                                                                                |
| ------------------------------------------- | ------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `chromium.launch()` fails silently          | Trying to launch Windows Chrome via pipe from WSL | Use `connectOverCDP` with a pre-launched Chrome                                                    |
| `page.keyboard.selectAll is not a function` | Method doesn't exist in Playwright                | Use `click({ clickCount: 3 })` or `.fill()`                                                        |
| Wrong API endpoint (404)                    | Guessed endpoint from docs                        | Use request interception to capture actual URLs                                                    |
| `browser.close()` kills Chrome              | Closes the browser process                        | Use `browser.disconnect()`                                                                         |
| Locator timeout on element                  | Element not visible or wrong selector             | Inspect element in Chrome DevTools first; use `page.pause()` to debug interactively                |
| Script runs but changes don't stick         | Form submit not triggered                         | Ensure you're clicking the submit/save button, not just filling fields                             |
| Pocket-ID OIDC passkey screen appears       | App requires passkey auth                         | Log in manually in Chrome first, then run the script (session persists)                            |
| `npm install playwright` takes a long time  | Downloading browser binaries                      | Add `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` — we use Windows Chrome via CDP, no local browsers needed |

---

## When to Use vs. Direct API

| Use Playwright                               | Use curl/API                              |
| -------------------------------------------- | ----------------------------------------- |
| App has no API                               | API is known                              |
| Need to discover what API calls the UI makes | Credentials/token already available       |
| Taking screenshots for verification          | Bulk operations (looping over many items) |
| OIDC/passkey login required mid-flow         | App is a standard REST service            |
| Testing actual user-facing behavior          |                                           |
