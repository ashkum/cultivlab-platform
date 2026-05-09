# CultivLab — Operator Installation Guide

**Status:** Skeleton — sections filled in sprint by sprint.
Target: a stranger with a GCP account and a domain can deploy from scratch in under 30 minutes.

---

## Prerequisites

_Filled in Sprint 1._

Tools required on the operator's machine, minimum versions, and install commands.

---

## GCP setup

_Filled in Sprint 1._

Creating the GCP project, enabling APIs, setting up billing alerts, running
`scripts/gcp-bootstrap.sh`.

---

## DNS configuration

_Filled in Sprint 1._

Which A and CNAME records to add at your registrar, in what order, and how to verify
propagation before continuing.

---

## VM provisioning

_Filled in Sprint 1._

Running `scripts/gcp-bootstrap.sh`, verifying the VM is reachable, SSH key setup.

---

## Bootstrap

_Filled in Sprint 1._

Running `scripts/bootstrap.sh` on the VM: Docker installation, Compose stack start, HTTPS
verification, first LiteLLM health check.

---

## LiteLLM and provider configuration

_Filled in Sprint 2._

Setting up provider API keys, verifying all three providers (Anthropic, OpenAI, Vertex AI)
respond via curl, configuring Slack alert webhooks.

---

## Open WebUI setup

_Filled in Sprint 3._

Connecting Open WebUI to LiteLLM, configuring the kid-mode system prompt, creating the first
operator account, verifying student signup is disabled.

---

## Cohort provisioning

_Filled in Sprint 3._

Preparing `students.csv`, running `scripts/provision-cohort.sh --dry-run`, running it for
real, verifying all 12 virtual keys and Open WebUI accounts exist.

---

## Student site setup

_Filled in Sprint 4._

Firebase Hosting project setup, running the site provisioning script, adding DNS CNAME
records for each student subdomain, verifying HTTPS on student URLs.

---

## Founder Console setup

_Filled in Sprint 5.5._

Building the console container, configuring the bcrypt password, verifying the dashboard
loads and all student actions work.

---

## Pre-cohort hardening checklist

_Filled in Sprint 5/6._

Full pre-cohort verification: backup test, alert test, pause/resume test, all acceptance
criteria from `docs/../README.md` checked off.

---

## Verification

_Filled in Sprint 1 (core), updated each sprint._

Health check commands to confirm each layer of the stack is functional.

---

## Troubleshooting

_Filled in Sprint 1 (basics), updated each sprint._

Common failure modes and their resolutions. Also see `docs/runbooks/`.
