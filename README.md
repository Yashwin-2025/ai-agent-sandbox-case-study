# Containing a Compromised AI Coding Agent

A hands-on security case study: running **Claude Code** inside an **NVIDIA OpenShell** sandbox and attacking it, including with prompt injection, to find out what actually stops a misbehaving agent.

> **Result:** with its guardrails turned off, the agent obeyed a hidden prompt injection and tried to send its environment to an external server, without telling the user. The sandbox blocked the connection and recorded it. The real API key was never visible inside the sandbox, and 22/22 isolation checks passed.

## Key results

| | |
|---|---|
| **22/22** isolation checks passed | non-root, no capabilities, no escalation, read-only system paths, no Docker access, default-deny egress (including raw IPs) |
| **Prompt injection contained** | free model obeyed the injection → connection **DENIED** and logged; Claude Haiku 4.5 detected it and refused |
| **Credential brokering** | the agent only sees an `openshell:...` placeholder; the stolen value returns **401** outside |
| **~25 escape attempts blocked** | fetch, git HTTPS/SSH, raw IPs, alternate ports, localhost, DNS tricks |
| **Finding** | the provider credential is available to every process the agent launches, confirmed with a controlled experiment. A broad `node` allowlist was fixed and re-verified; an upstream feature request is drafted |
| **Negative control** | allowing a host in the live policy flipped BLOCKED → HTTP 200 as soon as the rule was added, which proves OpenShell does the blocking |

Every result is attributed to the layer that enforced it: **Linux permissions**, **container isolation**, **OpenShell policy**, or **agent behavior**. That distinction is the core of the study.

## Architecture

```
 Host (macOS)
 ├─ OpenShell gateway ─ holds real API key + policies (mTLS)
 └─ Docker Desktop VM
    ├─ supervisor: policy proxy · policy DNS · credential injection · OCSF audit log
    └─ sandbox (network=none, uid 1000, caps dropped, Landlock)
         Claude Code ──all traffic──► supervisor ──allowlist only──► openrouter.ai
```

## Repository

| Path | What it is |
|---|---|
| [case-study/REPORT.md](case-study/REPORT.md) | **Start here:** threat model, method, results, findings, enterprise recommendations |
| [case-study/RESULTS.md](case-study/RESULTS.md) | Every test result with its enforcing layer and evidence |
| [case-study/run-case-study.sh](case-study/run-case-study.sh) | One-command reproduction |
| [case-study/run-tests.sh](case-study/run-tests.sh) | The 22 isolation checks (run inside the sandbox) |
| [case-study/scenarios/](case-study/scenarios/) | Prompt-injection repo, agent attack runner, process-ancestry experiment |
| [case-study/evidence/](case-study/evidence/) | Raw outputs, OCSF network logs, agent transcripts, policies |
| [case-study/UPSTREAM_ISSUE_DRAFT.md](case-study/UPSTREAM_ISSUE_DRAFT.md) | Feature request drafted from the finding |
| [OPENSHELL_SETUP.md](OPENSHELL_SETUP.md) | Setup guide: six issues hit along the way, with root causes and fixes |
| [Dockerfile.claude](Dockerfile.claude) · [provider-openrouter.yaml](provider-openrouter.yaml) | Agent image and the provider policy under test |

## Reproduce

Requirements: macOS with Docker Desktop (**Settings → Resources → Network → Enable host networking**), OpenShell (`brew install openshell`), and an OpenRouter API key registered as the `openrouter` provider.

```sh
openshell profile import --file provider-openrouter.yaml     # once: register the profile
OPENROUTER_API_KEY=sk-or-... openshell provider create --name openrouter --type openrouter --credential OPENROUTER_API_KEY   # once: store the key
case-study/run-case-study.sh                                 # tests + ancestry experiment (free)
case-study/run-case-study.sh --scenarios anthropic/claude-haiku-4.5   # + agent attacks (paid, ~$0.75)
```

To use the sandbox interactively:

```sh
docker build -f Dockerfile.claude -t claude-agent:local .
openshell sandbox create --name claude-openrouter --from claude-agent:local --provider openrouter -- bash
# inside the sandbox:  claude
```

## Stack
NVIDIA OpenShell 0.1.2 · Claude Code 2.1.285 · Docker Desktop · OpenRouter (Claude Haiku 4.5, cohere north-mini-code) · Landlock · OCSF
