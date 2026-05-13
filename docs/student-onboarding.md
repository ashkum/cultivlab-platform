# CultivLab — Student Onboarding Guide

This is what the operator walks students through on Day 1. Every step has been validated against the
live platform.

---

## What students need (before Day 1)

**Hardware:** A laptop running macOS or Windows. Chromebooks are not supported (VS Code and
Continue.dev require a local install).

**Software to install in advance (optional but speeds up Day 1):**

- [VS Code](https://code.visualstudio.com/download) — free, available for Mac and Windows
- A modern web browser (Chrome or Firefox recommended)

**What to bring:**

- Your onboarding card (distributed by the operator — keep it safe, it has your login credentials)
- The laptop you will use for all three weeks
- Charger

---

## Step 1 — Receive your onboarding card

The operator will hand you a printed or digital onboarding card. It contains:

| Item               | What it looks like            | What it's for               |
| ------------------ | ----------------------------- | --------------------------- |
| Chat URL           | `https://chat.cultivlab.com`  | Log in to chat with AI      |
| Chat username      | your email address            | Login to the chat interface |
| Chat password      | a random string (e.g. `x7k…`) | Login to the chat interface |
| API key            | starts with `sk-…`            | Connects VS Code to the AI  |
| Your personal site | `https://lNN.cultivlab.com`   | Where your projects go live |

Keep the card somewhere safe. If you lose it, tell the operator — they can look up your credentials.

---

## Step 2 — Log in to the chat interface

1. Open your browser and go to **`https://chat.cultivlab.com`**
2. Enter the email and password from your onboarding card
3. Click **Sign in**

You should see the CultivLab chat screen. In the top-left, there is a model selector dropdown. Click
it and choose one of:

- **Claude (CultivLab)** — good for writing, explaining, and creative tasks
- **GPT-4o mini (CultivLab)** — fast, good for coding questions
- **Gemini 2.5 Flash (CultivLab)** — Google's model, good for research questions

Type a message and press Enter. You should get a reply within a few seconds.

**If you see an error or no response:** tell the operator. Do not try to log in with a different
account.

---

## Step 3 — Install VS Code

VS Code is the code editor you will use to write and edit your website files.

**macOS:**

1. Go to [https://code.visualstudio.com/download](https://code.visualstudio.com/download)
2. Click **Mac** — download the `.zip` file
3. Open the downloaded zip — it extracts `Visual Studio Code.app`
4. Drag `Visual Studio Code.app` into your **Applications** folder
5. Open it from Applications (right-click → Open the first time if macOS asks for confirmation)

**Windows:**

1. Go to [https://code.visualstudio.com/download](https://code.visualstudio.com/download)
2. Click **Windows** — download the installer (`.exe`)
3. Run the installer, accept defaults, click through to Finish
4. Open VS Code from the Start menu

**Verify:** VS Code opens and shows a Welcome tab.

---

## Step 4 — Install extensions

You need two extensions: **Continue** (AI coding assistant) and **Live Server** (local preview).

In VS Code, click the Extensions icon in the left sidebar (it looks like four squares), or press
`Cmd+Shift+X` (Mac) / `Ctrl+Shift+X` (Windows).

**Install Continue:**

1. In the search box, type `Continue`
2. Find the extension published by **Continue** (identifier: `Continue.continue`)
3. Click **Install**
4. When prompted, reload VS Code

Verify: a triangle icon (▶) appears in the left sidebar.

**Install Live Server:**

1. In the search box, type `Live Server`
2. Find the extension published by **Ritwick Dey** (identifier: `ritwickdey.LiveServer`)
3. Click **Install**

Verify: a **Go Live** button appears in the VS Code status bar at the bottom right.

---

## Step 5 — Configure Continue

Continue connects VS Code to the CultivLab AI models using the API key from your onboarding card.

1. Click the **Continue** icon (▶) in the left sidebar
2. Click the **gear icon (⚙)** in the top right of the Continue panel → **Open config.json**

The file opens in VS Code. Replace the entire contents with the following — substituting your actual
API key from the onboarding card:

```json
{
  "models": [
    {
      "title": "Claude (CultivLab)",
      "provider": "openai",
      "model": "claude-sonnet-4-6",
      "apiBase": "https://api.cultivlab.com/v1",
      "apiKey": "sk-PASTE_YOUR_KEY_HERE"
    },
    {
      "title": "GPT-4o mini (CultivLab)",
      "provider": "openai",
      "model": "gpt-4o-mini",
      "apiBase": "https://api.cultivlab.com/v1",
      "apiKey": "sk-PASTE_YOUR_KEY_HERE"
    },
    {
      "title": "Gemini 2.5 Flash (CultivLab)",
      "provider": "openai",
      "model": "gemini-2.5-flash",
      "apiBase": "https://api.cultivlab.com/v1",
      "apiKey": "sk-PASTE_YOUR_KEY_HERE"
    }
  ],
  "tabAutocompleteModel": {
    "title": "Autocomplete (CultivLab)",
    "provider": "openai",
    "model": "gpt-4o-mini",
    "apiBase": "https://api.cultivlab.com/v1",
    "apiKey": "sk-PASTE_YOUR_KEY_HERE"
  }
}
```

Replace `sk-PASTE_YOUR_KEY_HERE` with your actual key (all four places — same key each time). Save
the file (`Cmd+S` / `Ctrl+S`). Continue reloads automatically.

**Verify:** In the Continue panel, pick **Claude (CultivLab)** from the model dropdown and type:

```
Write a Python function that adds two numbers.
```

A response should appear within 5–10 seconds. If not, check:

- The `apiKey` field has your full key starting with `sk-` (no extra spaces or line breaks)
- The `apiBase` ends exactly with `/v1` (no trailing slash)
- Tell the operator if it still doesn't work

> **Note:** All three models use `"provider": "openai"` — this is correct. The CultivLab platform
> speaks OpenAI-compatible format for all models, so VS Code talks to everything the same way.

---

## Step 6 — Get the starter project

The operator will distribute a starter project folder (either as a zip file or directly to your
laptop). It contains:

```
my-project/
├── index.html    ← your home page
├── style.css     ← your styles
└── script.js     ← your JavaScript (optional)
```

Save the folder to your Desktop. In VS Code: **File → Open Folder** → select the folder.

You should see the three files listed in the Explorer sidebar (left panel).

---

## Step 7 — Preview locally with Live Server

Before deploying, you can preview your site on your own laptop.

1. In the VS Code Explorer, click on `index.html` to open it
2. Click **Go Live** in the status bar at the bottom right
3. Your browser opens at `http://127.0.0.1:5500` showing your site

Any time you save a file in VS Code, the browser refreshes automatically.

To stop Live Server, click the port number in the status bar (it will say something like **Port:
5500**) and the button toggles back to **Go Live**.

---

## Step 8 — Deploy your site

When you are ready to put your site on the internet at your personal URL
(`https://lNN.cultivlab.com`), tell the operator — they will deploy it for you.

**What you do:**

1. Save your file in VS Code (`Cmd+S` / `Ctrl+S`)
2. Tell the operator: "I'm ready to deploy `index.html`" (or whatever your filename is)
3. The operator copies the file to the server
4. Open your browser and go to `https://lNN.cultivlab.com` — your site is live

**Each file gets its own URL:**

- `index.html` → `https://lNN.cultivlab.com/` (your home page)
- `game.html` → `https://lNN.cultivlab.com/game.html`
- `style.css` → `https://lNN.cultivlab.com/style.css`

You can have multiple files on your site. Deploying a new version of `index.html` replaces the old
one — deploying `game.html` does not affect `index.html`.

---

## Iterating over the 3 weeks

The daily loop:

1. **Edit** — change `index.html` (or any file) in VS Code with AI help
2. **Preview** — save and check Live Server at `localhost:5500`
3. **Deploy** — tell the operator your file is ready; they push it live
4. **Share** — send your `https://lNN.cultivlab.com` URL to anyone you want

**Using AI chat for ideas:** go to `https://chat.cultivlab.com`, pick a model, and ask questions
like "What should I add to make my website more interesting?" or "Can you explain what CSS flexbox
does?"

**Using Continue in VS Code for coding help:** open a file, select some code, press `Cmd+L` (Mac) /
`Ctrl+L` (Windows) to open the Continue chat with the code pre-loaded. Ask questions like "What does
this code do?" or "Can you add a button that changes the background colour?"

**Saving your work:** your files live on your laptop. VS Code does not auto-save by default — enable
it at **File → Auto Save**, or remember to press `Cmd+S` / `Ctrl+S` often.

---

## Getting help

| Problem                                | What to do                                                                                 |
| -------------------------------------- | ------------------------------------------------------------------------------------------ |
| Chat shows "Error" or no response      | Wait 10 seconds and try again; if it persists, tell the operator                           |
| "Budget exceeded" message in chat      | Your weekly AI budget has run out — tell the operator                                      |
| Continue shows no response in VS Code  | Check config.json has the right API key; tell the operator if it still fails               |
| Site not updated after deploy          | Tell the operator to re-deploy; hard-refresh your browser (`Cmd+Shift+R` / `Ctrl+Shift+R`) |
| Site shows old content after deploying | Hard-refresh your browser (`Cmd+Shift+R` / `Ctrl+Shift+R`) to clear the cache              |
| VS Code extension not showing up       | Reload VS Code (`Cmd+Shift+P` → "Developer: Reload Window")                                |
| Lost your onboarding card              | Tell the operator — they can look up your credentials and reset your password if needed    |
