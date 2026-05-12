# Runbook: Continue.dev Pre-Cohort Smoke Test

**When to run this runbook:**

Run once before each cohort, after `provision-cohort.sh` has created student virtual keys and before
Day 1. Continue.dev's configuration UI changes between releases — this verifies the current version
works with the platform proxy before students encounter it.

**Time required:** 10–15 minutes.

**Prerequisites:**

- `cohort-keys-${COHORT_NAME}.csv` exists (output of `provision-cohort.sh`).
- `api.${DOMAIN}` is reachable and LiteLLM is healthy.
- VS Code is installed on your laptop.
- You have access to the LiteLLM admin UI at `https://admin.${DOMAIN}/ui`.

---

## 1. Install Continue.dev (if not already installed)

In VS Code, open the Extensions panel (`Cmd+Shift+X` / `Ctrl+Shift+X`), search for **Continue**, and
install the extension published by **Continue.dev** (identifier: `Continue.continue`). Reload VS
Code when prompted.

Verify: a **Continue** icon (triangle with horizontal lines) appears in the left sidebar.

---

## 2. Pick a test virtual key

Open `cohort-keys-${COHORT_NAME}.csv` and copy the `key` value from **any one student row** (e.g.
the first student). This is the `sk-...` plaintext key. You will use it to impersonate that student
during the smoke test.

Note the student's `slug` — you will verify their spend attribution in step 5.

---

## 3. Configure Continue.dev

Click the **Continue** icon in the VS Code sidebar. On first launch it may show an onboarding flow —
skip through it to reach the chat panel.

Open the Continue config file:

- **From the chat panel:** click the gear icon (⚙) at the top right → **Open config.json**.
- **Direct path (macOS/Linux):** `~/.continue/config.json`
- **Direct path (Windows):** `%USERPROFILE%\.continue\config.json`

Replace the contents with:

```json
{
  "models": [
    {
      "title": "Claude (CultivLab)",
      "provider": "openai",
      "model": "claude-sonnet-4-6",
      "apiBase": "https://api.YOUR_DOMAIN/v1",
      "apiKey": "sk-PASTE_STUDENT_KEY_HERE"
    },
    {
      "title": "GPT-4o mini (CultivLab)",
      "provider": "openai",
      "model": "gpt-4o-mini",
      "apiBase": "https://api.YOUR_DOMAIN/v1",
      "apiKey": "sk-PASTE_STUDENT_KEY_HERE"
    }
  ],
  "tabAutocompleteModel": {
    "title": "Autocomplete (CultivLab)",
    "provider": "openai",
    "model": "gpt-4o-mini",
    "apiBase": "https://api.YOUR_DOMAIN/v1",
    "apiKey": "sk-PASTE_STUDENT_KEY_HERE"
  }
}
```

Replace `YOUR_DOMAIN` with your actual domain and `sk-PASTE_STUDENT_KEY_HERE` with the key from
step 2. Save the file — Continue.dev hot-reloads the config.

> **Note:** The `"provider": "openai"` field is correct even for Claude and Gemini models. LiteLLM
> exposes an OpenAI-compatible API, so Continue.dev talks to it as an OpenAI provider regardless of
> which underlying model is selected.

---

## 4. Verify chat works

In the Continue panel, select **Claude (CultivLab)** from the model dropdown. Type a short message:

```
Write a Python function that adds two numbers.
```

Expected result: a response appears within 5–10 seconds with valid Python code.

If no response appears after 15 seconds, check:

- The model dropdown shows the correct model name (not a cached stale model).
- `apiBase` in config.json ends with `/v1` (not `/v1/` and not the bare domain).
- The virtual key is correct (no extra spaces, no line break).
- `https://api.${DOMAIN}/health/liveliness` returns 200 from your browser.

---

## 5. Verify autocomplete works

Open any `.py` (or `.js`) file in VS Code. Start typing a function:

```python
def greet(name):
    return
```

Place the cursor after `return ` and pause for 1–2 seconds. Continue.dev should show a grey inline
suggestion. Press `Tab` to accept it.

If autocomplete does not trigger:

- Confirm the `tabAutocompleteModel` block is present and correct in config.json.
- Check VS Code settings: `Cmd+,` → search for **editor.inlineSuggest.enabled** → must be `true`.
- Some Continue.dev versions require enabling autocomplete in the Continue panel settings icon.

---

## 6. Verify spend attribution in LiteLLM

Open `https://admin.${DOMAIN}/ui` → **Virtual Keys** → find the key you used. The **Spend** column
should show a non-zero value from the test requests.

Alternatively, check the usage tab:

```sh
source .env
curl -fsSL https://api.${DOMAIN}/key/info \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  | jq '.info | {spend, max_budget, budget_duration}'
```

Expected: `spend` is greater than `0.000`.

The student's usage also appears in **LiteLLM admin → Usage → By User** — look for the slug value
that was embedded in the key alias during provisioning.

---

## 7. Test budget enforcement (optional but recommended)

If you want to confirm that a student with an exhausted budget is blocked:

1. In the LiteLLM admin UI, temporarily set the test key's `max_budget` to `0.0001` (a fraction of a
   cent — the next request will exceed it).
2. Send another chat message from Continue.dev.
3. Expect an error response (HTTP 429 or a budget-exceeded message).
4. Reset `max_budget` back to `${STUDENT_MAX_BUDGET}` in the admin UI.

---

## 8. Clean up

- Close or discard the test config.json — students will configure their own copy.
- No spend cleanup needed: the test spend is real but negligible (typically < $0.002 per test).

If you want to zero out the test student's spend before the cohort starts, do so in the LiteLLM
admin UI: Virtual Keys → test key → edit → reset spend to `0`.

---

## 9. Document the Continue.dev version tested

Record the version you verified in the sprint report or cohort prep notes:

```
VS Code: X.Y.Z
Continue.dev: vX.Y.Z  (Help → About → Extensions in VS Code)
LiteLLM: ${LITELLM_VERSION}
Tested: YYYY-MM-DD  Operator: <your name>
Result: chat OK | autocomplete OK | spend attributed OK
```

Continue.dev version updates can change the config schema or UI. If you upgrade Continue.dev between
cohorts, re-run this runbook.

---

## Troubleshooting

**`401 Unauthorized` in Continue.dev.** The virtual key is wrong or has been revoked. Re-copy the
plaintext `key` from `cohort-keys-${COHORT_NAME}.csv` — it must start with `sk-`. Do not use the
`key_alias` column.

**`404 Not Found` on the API base URL.** The `apiBase` is incorrect. It must be
`https://api.${DOMAIN}/v1` (with `/v1`, no trailing slash). Confirm
`https://api.${DOMAIN}/health/liveliness` is reachable first.

**Continue.dev shows "No models found" or a blank model list.** The config.json syntax is invalid.
Open it and run it through a JSON linter. Common mistake: trailing comma after the last element in
an array or object.

**Chat works but autocomplete never triggers.** Some Continue.dev versions require the
`tabAutocompleteModel` key at the top level of config.json (not nested under `models`). Confirm the
structure matches the template in step 3 exactly.

**LiteLLM shows spend = 0 after requests.** The `user` field attribution requires the Open WebUI
Filter Function (ADR-011) when traffic goes through Open WebUI. Direct Continue.dev requests bypass
Open WebUI — spend should still increment on the virtual key even without the `user` field. If spend
is not incrementing, check LiteLLM logs:

```sh
sudo docker compose --env-file /opt/cultivlab/.env logs litellm --tail=50 | grep -i "spend\|error"
```
