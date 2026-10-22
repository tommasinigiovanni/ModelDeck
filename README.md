# ModelDeck

A native macOS dashboard for your Mac, local LLMs, and Claude Code / Codex subscription quotas.

Built with SwiftUI and Swift Charts. macOS 14 or later. No package dependencies, telemetry, browser cookies, or model inference requests.

![ModelDeck dashboard, synthetic demonstration data](docs/dashboard.png)

The screenshot uses **synthetic demonstration data**, not a real account or a performance benchmark. The initial interface is in Italian.

## Features

- Live CPU, memory, swap, disk capacity, network throughput, battery and thermal state.
- Optional GPU utilization when exposed by the Mac's IORegistry. Unavailable metrics display `—`.
- Light, dark and system appearance, shared by the dashboard and menu bar panel.
- Local model inventory from Ollama, LM Studio and Unsloth, plus custom GGUF / Safetensors folders.
- Loaded-model state and Ollama GPU allocation when reported by the local server.
- Codex quota windows, percentages used, reset times and plan when provided.
- Claude Code quota windows via its documented status line data.
- Process detail with CPU, resident memory, PID, path, thread count and detected GPU clients.
- Confirmed termination (SIGTERM) or forced termination (SIGKILL) for your own processes, with PID identity validation.
- Native menu bar icon: left click for the panel, right click for actions, and dashboard reopening after closing its window.
- Full dashboard, Finder shortcuts and launch at login.

[Light appearance](docs/dashboard-light.png) · [Process detail preview](docs/processes.png). All previews use synthetic data.

The project name and icon are provisional while the feature set is being developed.

## Build and run

Install Xcode (or the Command Line Tools) with a Swift 5.10+ toolchain, then:

```sh
git clone https://github.com/tommasinigiovanni/ModelDeck.git
cd ModelDeck
bash scripts/build.sh
open build/ModelDeck.app
```

To keep the app installed, copy `build/ModelDeck.app` to `~/Applications` **before connecting Claude Code**. The status line references the executable in its installed location. Moving the app later requires restoring and reconnecting the bridge.

```sh
mkdir -p ~/Applications
ditto build/ModelDeck.app ~/Applications/ModelDeck.app
open ~/Applications/ModelDeck.app
```

The local build is ad hoc signed. There is no Developer ID signature, notarization, automatic updater or App Store distribution in this initial version. CI produces an app archive for its runner's architecture; it is not a universal binary.

For development, `swift run ModelDeck` works. A generated `ModelDeck.xcodeproj` is also included. To regenerate it after changing targets, install [XcodeGen](https://github.com/yonaskolb/XcodeGen) and run `xcodegen generate`.

## Connect your tools

### Ollama

Start your existing Ollama server. ModelDeck reads [`GET /api/tags`](https://docs.ollama.com/api/tags) and [`GET /api/ps`](https://docs.ollama.com/api/ps) at `http://127.0.0.1:11434`. If the server is offline, it reads manifests in `~/.ollama/models/manifests`. For a custom `OLLAMA_MODELS` directory, run the server with that directory: the API remains authoritative.

### LM Studio

Start LM Studio's local server. ModelDeck uses [`GET /api/v1/models`](https://lmstudio.ai/docs/developer/rest/list) at `http://127.0.0.1:1234`, with a v0 fallback on HTTP 404. If authentication is enabled, save the server token in Settings; it is stored in the macOS Keychain.

Offline discovery scans `~/.lmstudio/models` and `~/.cache/lm-studio/models`. Add custom locations in Settings. Safetensors shards in a directory containing `config.json` are grouped as one model. Projector files prefixed `mmproj` are excluded. Loaded state is unknown while the API is unavailable. Embedding models are included.

### OpenAI / Codex

Install [Codex CLI](https://learn.chatgpt.com/codex) and sign in with `codex login`. ModelDeck starts a short-lived `codex app-server` process, initializes JSON-RPC, calls [`account/rateLimits/read`](https://learn.chatgpt.com/docs/app-server), and stops it. It never starts a thread or turn. Codex manages its own authentication; ModelDeck does not copy its credentials.

These are **Codex usage quotas associated with your ChatGPT plan**, not every ChatGPT model's message limit and not OpenAI API billing. Missing data stays unavailable. All returned quota buckets are displayed; values are not inferred from token counts.

### Unsloth

ModelDeck reads the local [Unsloth Studio](https://unsloth.ai/docs/get-started/install/mac) OpenAI-compatible `GET /v1/models` catalog and, when available, `GET /api/inference/loaded-models`. The default endpoint is `http://127.0.0.1:8888`; change it in Settings. An optional API key is saved in the macOS Keychain. ModelDeck does not read Unsloth authentication databases or mint keys.

Offline discovery scans the `models`, `library`, `outputs` and `exports` directories under `~/.unsloth/studio`, plus Hugging Face snapshots under `~/.cache/huggingface/hub`. The shared HF cache is grouped under Unsloth in the inventory; its presence does not mean a model was created or exclusively used by Unsloth. Cache symlinks are followed for weight sizes, and the `refs/main` snapshot is preferred when present.

Three model-directory preferences (`hugging_face_cache_home`, `hugging_face_cache_history`, `hugging_face_download_homes`) are read from Unsloth's `app_settings` table in immutable read-only mode. This uses the database's last checkpoint and does not create sidecars or read chat tables. Active API listings are authoritative when available. Additional cache/export directories and external disks can be added with **Aggiungi cartella Unsloth**. If the local schema changes or a database cannot be read, manual folders remain available.

### Claude / Claude Code

In Settings, choose **Collega Claude Code**, then restart Claude Code and send a message. A compatible Claude subscription and a Claude Code version exposing [`rate_limits` in status line JSON](https://code.claude.com/docs/en/statusline) are required. Quotas arrive after responses and may be absent for some account types or windows.

The bridge updates `~/.claude/settings.json`, preserves other settings, and chains your previous status line command with its original input. It stores the previous status line configuration in `~/Library/Application Support/ModelDeck/claude-bridge.json`. Use **Ripristina status line** before uninstalling ModelDeck. If another tool changes the status line after installation, restoration refuses to overwrite it; the backup remains available.

The same reversible setup is available from the installed app's command line:

```sh
~/Applications/ModelDeck.app/Contents/MacOS/ModelDeck --connect-claude
# To restore the previous status line:
~/Applications/ModelDeck.app/Contents/MacOS/ModelDeck --disconnect-claude
```

Only quota percentages, reset timestamps and capture time are written to `claude-usage.json` in the same application support directory (permissions `0600`). No prompts, transcript paths, tokens, email addresses or account identifiers are stored. The bridge does not make network requests. Claude's quota display updates from active sessions; it is not independent background polling. Project-specific status line overrides may take precedence over the user settings bridge.

## Refresh and metric semantics

System metrics refresh every 2 seconds by default (configurable to 5 or 10). Model discovery refreshes every 30 seconds; Codex quotas every 90 seconds. Claude snapshots older than 10 minutes are marked for refresh. Reset windows that have expired are marked as needing new data, without assuming 0% usage.

Memory is sampled from Mach VM statistics and excludes file cache and purgeable pages; it can differ from Activity Monitor. Disk availability uses the home volume's immediately available capacity. Model sizes are logical weight sizes and can overcount shared Ollama blobs. Network counters cover active `en*` interfaces, avoiding VPN/bridge duplication. The first CPU/network sample has no preceding delta and displays `—`. On counter resets/wraps, network deltas are unavailable for that sample.

GPU registry counters are not a stable cross-model API; unsupported Macs display `—`. Temperature, power draw, memory bandwidth and per-model token speed are not estimated. Unified RAM is shared with the GPU; model file size is not runtime memory consumption.

## Process inspection and termination

Open **Processi**, or click a CPU/memory/GPU metric card. The process list refreshes every three seconds while visible and supports name/PID search, CPU/memory/GPU sorting, and a current-user filter. Process CPU is measured from cumulative nanosecond deltas: **100% is one core**, so a process can exceed 100%. Process memory is resident RAM and need not sum to the dashboard's memory figure.

GPU client connections are identified from IORegistry. A connection is not proof of current GPU activity. Per-process GPU time is sampled through Mach `TASK_POWER_INFO_V2` only where permissions and driver counters permit it. Unsupported or constant-zero counters display **Client** / `—`, without distributing the total GPU percentage across processes. The GPU filter lists detected clients even when percentages are unavailable.

Selecting a row shows PID, executable path, owner UID and thread count. **Arresta…** offers graceful termination or forced termination, each with an in-app confirmation. ModelDeck verifies the process's PID plus start time immediately before signalling and permits only processes owned by the current user. PID 1, critical named system processes and ModelDeck itself are protected. No administrator helper or privilege escalation is used. Termination can lose unsaved changes in the selected application.

## Privacy and development

System and inventory reads stay local. Local HTTP endpoints are restricted to loopback and redirects are refused. Codex CLI makes its own authenticated request to OpenAI to fetch quotas. ModelDeck has no analytics or update service. The app is not sandboxed because it needs model folder access and CLI execution; no administrator privileges are required.

```sh
swift test
swift run ModelDeck --diagnostics
swift run ModelDeck --demo
.build/debug/ModelDeck --preview docs/dashboard.png
.build/debug/ModelDeck --preview docs/dashboard-light.png --light
.build/debug/ModelDeck --preview docs/processes.png --processes
.build/debug/ModelDeck --check-menu
```

Tests cover API formats, unavailable versus zero values, multi-bucket quotas, sanitized quota persistence, HF cache symlinks/revisions, Unsloth settings read-only behavior, endpoint restrictions, reversible Claude status line installation, CPU delta units and process termination identity checks. The process termination test creates and stops only its own disposable child process. `--check-menu` exercises native panel opening/closing, template icon configuration and dashboard reopening.

## Italiano

ModelDeck riunisce metriche del Mac, modelli LLM locali e quote degli abbonamenti AI. Le percentuali indicano **quota utilizzata**, con finestre e reset forniti dal servizio. Per iniziare, compila l’app, copiala in `~/Applications` e aprila. In **Impostazioni** puoi aggiungere cartelle, configurare i server e collegare Claude Code. Per Codex viene utilizzato il login già presente nella CLI.

MIT licensed. This project is independent and is not affiliated with Apple, Anthropic, OpenAI, Ollama, or LM Studio.
