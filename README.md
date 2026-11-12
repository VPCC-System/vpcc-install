# vpcc-install

The one line that installs VPCC on a Mac. This repo is public and holds only `install.sh` (plus its tests). It contains no company rules, no secrets and no tokens: everything else lives in a private repo that you can only read once you are in the company's GitHub organization.

```
curl -fsSL https://raw.githubusercontent.com/VPCC-System/vpcc-install/main/install.sh | bash
```

Copy the line exactly (copy and paste, don't retype it): it must start with `https://`. A plain `http://` line may still work (GitHub redirects it to https), but that first request isn't protected, so it can be read or changed on the way; a typo fetches nothing or another site.

Want to see what it would do first? Add `--dry-run`. It changes nothing. On a Mac without VPCC (and with GitHub CLI already logged in) it downloads the newest release into a temp folder outside `~/.vpcc`, checks it, and runs that release's installer with `--dry-run`: you see every folder it would move with its size (e.g. "would move ~/.claude (27 GB) → ~/.claude-old-2026-…"), every Keychain login it would delete, the cswap uninstall, and the shell-file and Dock edits. The temp folder is removed afterwards. Without a GitHub login yet, it only lists the steps:

```
curl -fsSL https://raw.githubusercontent.com/VPCC-System/vpcc-install/main/install.sh | bash -s -- --dry-run
```

Or read the script before running it: open the same URL in a browser, or download it with `curl -fsSL <url> -o install.sh`, read it, then run `bash install.sh`.

## What you need
- A Mac with macOS 15 or newer.
- A GitHub account that has been invited to the company's GitHub organization (your lead sends the invite). Accept it before you start.
- About 15 minutes. Everything goes into your own home folder (no `sudo`). macOS may ask for your Mac password: once for Command Line Tools, once when you drag Claude into Applications.

## What happens, step by step
1. **Checks this Mac.** macOS 15 or newer, and the `jq` tool that comes with it. Example: on macOS 14 it stops and says "VPCC needs macOS 15 or newer; update in System Settings > General > Software Update".
2. **Command Line Tools (only if missing).** These are Apple's free developer basics (they include `git`). A macOS dialog appears: click **Install** (not "Get Xcode") and accept the licence. It takes about 10 minutes; the Terminal window waits and prints one dot per minute.
3. **GitHub CLI (`gh`, only if missing).** Downloads GitHub's official `gh` for Macs at a fixed version, checks its checksum **before** unpacking it, and puts it in `~/.vpcc/bin/`. If you already have `gh`, it is used as it is.
4. **GitHub login.** If you aren't logged in yet, your browser opens: copy the one-time code shown in Terminal, paste it in the browser and approve. Your login is stored by `gh` in the macOS Keychain, not in any file of this repo. Then `gh auth setup-git` lets `git` use the same login. Last, it checks that you can see the private `vpcc` repo. If you can't yet, it stops with: "ask your lead for the GitHub org invite".
5. **Downloads VPCC.** Reads the list of releases from the private repo, takes the newest release marked good, checks its checksum, refuses any archive that would write outside its folder, and unpacks it into `~/.vpcc/releases/<version>/` (e.g. `~/.vpcc/releases/1.0.0/`). Then `~/.vpcc/setup` becomes a link to it. If something fails here, nothing is left behind.
6. **Runs the real installer** from that release (`~/.vpcc/setup/install.sh`). That one shows you its own steps (your accounts file from the VPCC owner, which it finds in Downloads; the Claude accounts, the app, the Dock icons). If you used Claude on this Mac before, it lists the old setup and asks "Set these aside?": type `y`, then Enter. No files are deleted (folders are moved and kept read-only); old logins are removed from the Keychain, cswap is uninstalled and the old `claude` alias lines are commented out, so each account logs in again. Quit the Claude app first (it asks you to, if it is open).

Before step 2 it asks once: "Continue? [Y/n]". Add `--yes` to skip that question (`... | bash -s -- --yes`). `--yes` skips only that question: it is not passed on, so the "Set these aside?" question above is always asked.

## Right after the install
In the same Terminal window `vpcc` is "command not found": that window started before VPCC added `~/.local/bin` to PATH (in `~/.zprofile`). Run `exec zsh -l` there first, or open a new Terminal window.

## Running it again
Safe. Steps already done are skipped (Command Line Tools, `gh`, the login). If VPCC is already installed, it says "VPCC 1.0.0 is already installed; running its installer to check everything" and runs that installer again; it doesn't download a newer release (use `vpcc update` for that).

## When it stops
Every message starts with `vpcc-install:` and says what to do next. Examples:
- "this copy has no GitHub org set": you used a copy of the line without the company's org name. Use the line your lead sent.
- "you're logged in to GitHub as robin-gh, but that account can't see .../vpcc yet": accept the org invite (or ask for it), then paste the line again.
- "~/.vpcc/setup is a folder, not a link to a release": an older install left a folder there. Move it aside as the message shows, then paste the line again.
- "don't run this with sudo": paste the line without `sudo`.

## For developers
- `bash tests/run.sh` runs the tests. They replace every outside command (`curl`, `gh`, `xcode-select`, `dscl`, ...) with stubs and use a scratch home folder; nothing on your Mac is changed.
- The org name (`VPCC_ORG` = `VPCC-System`) and the pinned GitHub CLI version and checksums (`GH_VERSION` = 2.103.3, `GH_SHA256_ARM64`, `GH_SHA256_AMD64`, checked against GitHub's own checksum file) sit at the top of `install.sh`. Without a valid checksum the script refuses to download `gh`.
- `VPCC_INSTALL_SOURCE=<file.tar.gz>` installs a local release instead of the GitHub one (for a scratch macOS user). It refuses to run when `HOME` is your real home folder, or when `VPCC_HOME` points into your real home outside `HOME` (the real home is looked up for your login, not taken from `$HOME` or `$USER`).
