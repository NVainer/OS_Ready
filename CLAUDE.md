# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Three **independent, standalone** post-install setup scripts. There is no shared library, no build
system, and no package manifest — each script is fetched raw from GitHub and executed directly, so
every one must stay a single self-contained file with no local dependencies.

| Path | Language | Target |
|------|----------|--------|
| `Power_Ubuntu/ubuntu.sh` | bash | Ubuntu 26.04 GNOME desktop |
| `Power_Hacker/ubuntu_kali.sh` | bash | same, plus pentest tooling (superset) |
| `Power_Windows/Power_Windows.ps1` | PowerShell 5.1+ | Windows 11 25H2+ |

`Power_Ubuntu/starship.toml` is served raw from GitHub and also copied from disk by `section_zsh`
when the repo is cloned locally (`SCRIPT_DIR` is preferred over the network).

## Commands

```bash
./Power_Ubuntu/ubuntu.sh --dry-run          # list sections that would run, change nothing
./Power_Ubuntu/ubuntu.sh --only=zsh,fonts   # run a single section end-to-end
./Power_Ubuntu/ubuntu.sh --list-sections
bash -n Power_Ubuntu/ubuntu.sh              # syntax check
shellcheck Power_Ubuntu/ubuntu.sh
```

```powershell
.\Power_Windows\Power_Windows.Test.ps1 -DryRun   # walk the whole flow, change nothing
```

There is no test framework and no CI. `Power_Windows.Test.ps1` is **not** a Pester suite — it is a
manually maintained, instrumented duplicate of `Power_Windows.ps1` (timestamped logs, per-step
PASS/FAIL, `-DryRun`). Any change to `Power_Windows.ps1` has to be mirrored into it by hand.

Real verification means running on a fresh VM and reading the log: `~/power_ubuntu.log`,
`~/ubuntu_kali.log`. The log is the primary debugging artifact — everything is tee'd to it with
ANSI codes stripped so it stays greppable.

## Bash script architecture

Both `.sh` scripts share the same framework:

- **`SECTIONS=(...)`** is the single source of truth for the main loop, `--help`, `--list-sections`,
  and `--only`/`--skip`. Adding a feature = add a name to the array and define `section_<name>()`.
  Order matters (`fonts` runs before `zsh` so the prompt has its glyphs on first launch).
- **Failure isolation:** the main loop runs each section in a subshell (`( set -e; "section_$s" )`),
  warns on non-zero, appends to `FAILED_SECTIONS`, and continues. `dev_step` does the same per-step
  inside `section_dev`, setting the caller's `DEV_FAILED` (dynamic scope) so the section still
  reports upward and a failed step reaches the closing summary.
- **`set -Eeuo pipefail`** is on, so `pipefail` is on. `long_cmd | grep -q pattern` can return 141:
  `grep -q` exits at the first match and SIGPIPEs the producer. `add_apt_source` already documents
  this trap. Do not put such a pipeline in a conditional.
- **Everything is `readonly`** (`VERSION`, `REAL_USER`, `REAL_HOME`, `SCRIPT_DIR`, …). Readonly
  attributes are **inherited by subshells**, so `$( . /etc/os-release && … )` aborts whenever
  os-release defines a name the script already froze (it defines `VERSION`).
- **Output plumbing:** fd 3/4 keep a handle on the real terminal. On an unattended TTY run
  (`--full`/`--yes`) `UI=true`: all stdout *and* stderr are redirected to the log only, and just the
  progress bar plus the closing screen reach the terminal. Anything the user must actually see has
  to be written to `>&3` explicitly — `log`/`warn`/`err` alone are invisible on screen in that mode.
- **Runs as the normal user**, calling `sudo` per command; `preflight` primes sudo and keeps it warm
  in a background loop. `REAL_USER`/`REAL_HOME` (not `$HOME`) are used for anything written into the
  user's home, so nothing ends up root-owned.

Helpers worth reusing instead of reinventing:

| Helper | Purpose |
|--------|---------|
| `install_available` | drops packages with no APT candidate so one missing package can't kill a section |
| `add_apt_source` | registers a third-party repo in deb822 `.sources` + keyring, cleans up legacy `.list` |
| `apt_install` / `apt_update` | `DEBIAN_FRONTEND=noninteractive` wrappers |
| `ask_yes` | honours `--full` / `--yes`; sections start with `ask_yes … \|\| return 0` |
| `pin_to_favorites` | append a `.desktop` to the GNOME dash |
| `install_meslo_nf` | Nerd Font download (not packaged in the archive) |

## Ubuntu 26.04 constraints that drive the design

- **sudo is `sudo-rs`**: `-E` is silently ignored and bare `--preserve-env` is gone. Pass variables
  inline (`sudo VAR=value cmd`), never `sudo -E`.
- **No `curl` in the default image** — `preflight` installs it. The README one-liner therefore uses
  `bash <(wget -qO- …)`; process substitution (not a pipe) so interactive prompts keep stdin.
- **Wayland-only, GNOME 50**: pixel geometry is ignored. Ptyxis is the only shipped terminal
  (`org.gnome.Terminal.ProfilesList` no longer exists) — size it in cells via
  `default-columns`/`default-rows`, and set colours on the per-profile schema keyed by
  `default-profile-uuid`.
- **GNOME 47+ has a native `accent-color`** that libadwaita apps honour; the old
  `gtk-theme Yaru-purple-dark` hack only recoloured legacy GTK3 apps.
- **apt 3.x** supports rollback (`sudo apt history-list` / `history-undo`), which is what the README
  offers instead of an uninstall path.
- Third-party APT repos are codename-pinned; Docker's has a `DOCKER_FALLBACK` (default `noble`) for
  the weeks after a new Ubuntu ships.

## Conventions

- Comments explain **why**, especially release-specific workarounds and things that were tried and
  failed (see the Ptyxis window-size and accent-colour comments). Match that density.
- `.gitattributes` forces `eol=lf` on `*.sh` and `*.zsh` — they are sourced/executed straight from
  raw GitHub and CRLF breaks them.
- `Power_Ubuntu` and `Power_Hacker` duplicate the framework and most sections verbatim. A fix in one
  usually belongs in the other; check both before considering a bug fixed. They have already
  drifted in places (e.g. `add_apt_source` writes its `.sources` file differently).
