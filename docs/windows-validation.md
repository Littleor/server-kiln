# Windows validation record

This record distinguishes automated checks from device acceptance. It is not a
claim that a Windows build proves macOS compatibility, or that a synthetic SSH
process test proves real SSH authentication.

## Automated local checks

Local run: Windows 11 x64 (build 26200), .NET SDK 10.0.404. The C# executable
passed 22 check groups, the repository suite passed 8 tests, and Release built
with zero warnings. WPF smoke rendering and self-contained packaging passed.
Workflow definitions also passed Actionlint 1.7.12 locally. The PR integration
starts from upstream 1.0.6 and keeps its Mac SSH / companion fixes intact.

- .NET SDK pinned by `global.json`; Release builds treat compiler warnings as errors.
- Shared Swift / C# fixtures cover GPU and CPU-only hosts, hidden container PIDs,
  multi-GPU attribution, driver failures, CRLF, memory units and missing values.
- Native Windows OpenSSH `-G` checks validate arguments, path quoting and trust-store policy without connecting to a server.
- Persistent child-process fixtures exercise split frames, stderr draining,
  timeouts, cancellation, bounded output and reuse of an authenticated process.
- SQLite checks cover aggregation, per-GPU queries, throttling, restart persistence,
  pruning, jobs and deletion. Recent samples check 5-second throttling, 10-minute
  retention, CPU-only data, clock corrections and removal.
- Notification checks cover debounce, mute, recovery, the opt-in Bark request
  contract and DPAPI storage. HTTP tests use a fake handler and send no real push.
- A per-user local pipe test checks repeated shortcut activation and timeout when
  no instance is listening. WPF smoke tests hide and restore the actual window.
- WPF smoke tests render all four history ranges, aggregate / per-GPU modes,
  utilization / memory selection, CPU-only and empty data, both languages in the
  fixed light palette, plus all settings pages and import dialogs. The redesigned caption
  checks maximize / restore, minimized-instance activation and the server action
  menu. Fleet checks cover Mac-compatible GPU-server denominators, configured busy
  thresholds, CPU-only / paused / offline hosts, retained server selection / tab /
  task expansion, PID reuse, sample-based start times, sidebar selection / detail
  binding, selected-server action context and literal PowerShell SSH arguments.
  WPF binding errors fail the smoke run. Synthetic exports cover the
  fleet, GPU meters, expanded task detail, jobs, per-GPU history, a compact window
  and settings. A legacy-settings test verifies that an obsolete dark-theme
  preference preserves hosts, identity paths, language and polling configuration.
- Package verification checks the SHA-256 manifest, archive paths, x64 PE host,
  desktop runtime, redistribution notices and exclusion of private runtime data.
- Python repository tests check publication boundaries and damaged / incomplete /
  unsafe Windows packages. Documentation links and collector export are checked.
- The real installer is exercised in isolated directories with Chinese / spaced
  paths: initial copy, upgrade, desktop / Start menu shortcut targets and manual
  removal preserve a separate synthetic user-data directory.

Run the complete local sequence:

```powershell
python scripts/check-public-tree.py --history
python scripts/check-docs.py
python -m unittest discover -s Tests/RepositoryTests
scripts/build-windows.ps1 -Package -Snapshots
```

The GitHub CI workflow runs both the existing Mac verification job and the new
Windows job on pushes and pull requests. The Mac UI, source-side signing
configuration and Mac release packaging scripts are unchanged. The shared Swift
parser now normalizes CRLF before splitting lines; the shared fixture caught the
previous empty host / process results for that input. A workflow run URL and its
results must be checked before marking remote macOS / Windows CI as passed.

## Remote CI

The pull request's current checks are the authoritative integration result.
The Mac verification job uses `macos-15-intel`: recent `macos-15` arm64 jobs
could not acquire a hosted runner, before any test step started. The Intel job
still runs Swift tests, builds the universal arm64 / x86_64 app, verifies both
localization resources and checks the ad-hoc signature. Windows CI runs the
repository and C# checks, WPF smoke rendering, bilingual snapshots, self-contained
ZIP validation and artifact upload.

Earlier [CI run 44013548247](https://github.com/JuntaoTang/server-kiln/actions/runs/44013548247)
passed both platforms at source commit `d439399`, including the then-current 47
Swift tests and universal packaging. That historical result does not establish
that a newer PR head passes; use the linked current PR checks for that.

Automated checks do not replace the device checks below or validate Apple
distribution signing.

## Real-server probe

The optional diagnostic command uses a server already configured by the user:

```powershell
dotnet Sources/ServerKiln.Windows/bin/Release/net10.0-windows/ServerKiln.dll --probe gpu-lab --samples 3
```

It uses strict verification and the same read-only collector as normal monitoring.
Output contains only success, sample count, GPU count and elapsed time; failures
report a category. Addresses, commands, usernames and private-key paths are omitted.
This check is never run against a production host by CI.

Local validation completed against two user-selected NVIDIA GPU hosts, using
their existing key files and previously verified fingerprints. Each completed
three consecutive samples through one persistent session; the hosts reported
one and four GPUs respectively. Only these anonymous counts are recorded here.
This does not establish encrypted-agent, jump-host, sleep/resume or long-duration
coverage, which remains in the device checklist below.

## Device acceptance still required

The following checks require selected hardware, user actions or credentials and
must not be inferred from automated fixture success:

| Check | Evidence to record |
| --- | --- |
| Real GPU and CPU-only SSH hosts | Probe result / successful metrics with keys and agents already configured |
| Encrypted key with Windows ssh-agent | Unlock key, verify noninteractive collection, then repeat after sign-in |
| Real ProxyJump / ProxyCommand | Test the supported native Windows proxy program |
| Sleep / resume and Wi-Fi changes | Connection recovers, stale data is distinguished, no duplicate sessions or spurious notifications |
| Multi-hour monitoring | Resource use, session count and history retention remain bounded |
| Windows notification delivery | Exercise an actual busy / idle transition and OS notification settings |
| Install / update / remove | Keep settings, keys and fingerprints; shortcuts and optional login startup point to the intended executable |
| Windows 10 / ARM64 | Device-specific build and runtime acceptance before expanding support claims |

Windows app signing, automatic updates and original iPhone interoperability are
outside the initial desktop support claim. The release workflow attaches verified
Windows artifacts only to a draft; it leaves an already published release unchanged.
