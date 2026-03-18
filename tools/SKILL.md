---
name: eda-playground
description: >
  Interact with EDA Playground (edaplayground.com) for SystemVerilog/UVM simulation workflows.
  Use this skill whenever the user wants to pull files from EDA Playground, push local changes
  back, run simulations, or download simulation logs. Also trigger when the user mentions
  EDA Playground URLs, wants to debug simulation failures, or says things like "run it on
  edaplayground", "push to playground", "pull from playground", "get the sim log", or
  references edaplayground.com links. This skill handles browser automation with persistent
  Google authentication so the user only logs in once.
---

# EDA Playground Skill

Automate EDA Playground workflows: pull source files, push changes, run simulations, and
download logs — all from the command line using Playwright browser automation.

## When to use

- User shares an edaplayground.com URL and wants to work with those files
- User wants to push local SystemVerilog/UVM changes back to EDA Playground
- User wants to run a simulation and see the results/log
- User wants to debug a simulation failure (pull files, fix, push, run, check log)

## Script location

All operations use a single script at:
```
~/.claude/skills/eda-playground/scripts/eda_playground.py
```

## Commands

### Login (one-time setup)
```bash
python3 ~/.claude/skills/eda-playground/scripts/eda_playground.py login
```
Opens a browser for Google login. Saves auth cookies to `~/.eda-playground-auth.json`
so future commands run without re-authentication. Re-run if auth expires.

### Pull files
```bash
python3 ~/.claude/skills/eda-playground/scripts/eda_playground.py pull <url> [--output-dir ./]
```
Downloads all source files (testbench + design tabs) from the playground to the local directory.
Does not require authentication (reads public page HTML).

### Push files
```bash
python3 ~/.claude/skills/eda-playground/scripts/eda_playground.py push <url> [--source-dir ./]
```
Uploads local files to the playground. Matches filenames to remote editor tabs.
Adds a version stamp comment at the top of each file so you can verify the upload worked.
Requires authentication (uses saved auth state).

### Run simulation
```bash
python3 ~/.claude/skills/eda-playground/scripts/eda_playground.py run <url> [--log-file sim.log]
```
Clicks the Run button, waits for simulation to complete, and saves the full log output.
Requires authentication. Default log file is `sim.log` in the current directory.

### Full cycle: push + run
```bash
python3 ~/.claude/skills/eda-playground/scripts/eda_playground.py push-run <url> [--source-dir ./] [--log-file sim.log]
```
Push local changes and immediately run the simulation. Combines push and run in one browser session.

## Version stamps

When pushing files, the script prepends a version comment to each file:
- `.sv` / `.v` / `.svh` / `.vh` files: `// EDA Playground v<N> | <timestamp>`
- `.md` files: `<!-- EDA Playground v<N> | <timestamp> -->`

The version number auto-increments based on any existing version stamp in the file.
This lets you verify on the EDA Playground page that your push actually took effect.

## Workflow

A typical debug cycle looks like:

1. **Pull**: `pull <url>` to get the current source files
2. **Edit**: Make fixes locally (Claude can help!)
3. **Push + Run**: `push-run <url>` to upload changes and run the sim
4. **Check log**: Read `sim.log` to see if the fix worked
5. **Repeat** as needed

## Authentication

Auth state is stored in `~/.eda-playground-auth.json`. The first time you push or run,
if no auth file exists, the script opens a headed browser for you to log in. After that,
it reuses the saved session. If the session expires, run `login` again or delete the auth
file and the next push/run will prompt re-login.

## Notes

- Pull works without auth (parses public HTML)
- Push/Run require you to own the playground (otherwise it creates a copy)
- The script uses Chromium via Playwright — run `playwright install chromium` if not installed
- Simulations have a 5-minute timeout by default
