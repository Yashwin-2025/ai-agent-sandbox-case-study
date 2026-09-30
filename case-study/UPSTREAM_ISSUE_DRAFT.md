# Draft: feature request for OpenShell (not yet filed)

> Review before posting. Target: the OpenShell GitHub issue tracker. Remove anything you don't want public.

**Title:** Provider credentials are usable by all descendants of an allowlisted binary; option to restrict to the binary itself

**Version:** OpenShell 0.1.2 (Homebrew gateway, Docker compute driver, macOS / Docker Desktop 29.5.3)

**Summary**
A provider profile's `binaries:` list appears to also match child processes of the listed binaries (process ancestry). With a provider that lists only the Claude Code binary, any process spawned by the agent (e.g. `node`, `git`, or a script the agent writes) can reach the provider endpoint, and the proxy injects the real credential into its requests.

**Reproduce**
1. Provider profile `openrouter`, endpoint `openrouter.ai:443` (rest, enforce), `binaries: [.../claude-code/bin/claude.exe]`.
2. In the sandbox, from a plain shell:
   `node -e "fetch('https://openrouter.ai/api/v1/key',{headers:{authorization:'Bearer '+process.env.OPENROUTER_API_KEY}})"` → **denied** (expected).
3. Run the same command from a Claude Code `SessionStart` hook (parent `claude.exe`) → **HTTP 200**: the real key was injected. `git ls-remote https://openrouter.ai/...` is likewise allowed only when launched by `claude.exe`.

**Expected / requested**
Ancestry matching is useful for interpreters, but for **credential-bearing provider rules** it widens who can use the secret to the agent's whole process tree. Would you consider:
- a per-rule option to match the exact binary only (no ancestor inheritance), and/or
- allowing L7 path/method restrictions on provider-owned rules (currently rejected with `provider-owned rules cannot receive L7 appends`), e.g. only `POST /api/v1/messages`?

**Evidence:** probe script and OCSF logs are available on request.
