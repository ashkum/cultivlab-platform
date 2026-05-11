# Continue.dev Configuration for CultivLab Students

Template rendered per-student during onboarding (Sprint 5+ work).

## What is Continue.dev?

Continue.dev is a free VS Code extension that provides AI chat and code completion inside the
editor. Routed through LiteLLM, students get per-student spend attribution and the safety moderation
pipeline still applies.

## Three models configured

| Model         | Best for                                 |
| ------------- | ---------------------------------------- |
| Claude Sonnet | Default chat — most thoughtful reasoning |
| GPT-4o Mini   | Alternative chat — different perspective |
| Gemini Flash  | Autocomplete — fast inline suggestions   |

## Template variables

`${DOMAIN}` — cohort domain (e.g. cultivlab.com) `${STUDENT_LITELLM_KEY}` — per-student API key from
Sprint 2

Both rendered via envsubst at provisioning time.

## Per-student delivery

Currently manual. Sprint 5+ work: extend provision-sites.sh to render and bundle per-student config.
