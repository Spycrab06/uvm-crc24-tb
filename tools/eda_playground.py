#!/usr/bin/env python3
"""
EDA Playground CLI — pull, push, run, and debug simulations.

Usage:
    eda_playground.py login
    eda_playground.py pull  <url> [--output-dir DIR]
    eda_playground.py push  <url> [--source-dir DIR]
    eda_playground.py run   <url> [--log-file FILE]
    eda_playground.py push-run <url> [--source-dir DIR] [--log-file FILE]
"""

import argparse
import json
import os
import re
import sys
import urllib.request
import urllib.error
from datetime import datetime
from pathlib import Path

AUTH_FILE = Path.home() / ".eda-playground-auth.json"
SIM_TIMEOUT_MS = 300_000  # 5 minutes

# Files to skip when reading local directory
SKIP_FILES = {
    "eda_playground.py", "pull_edaplayground.py", "push_edaplayground.py",
    ".DS_Store", "sim.log",
}


# ─── Version Stamps ─────────────────────────────────────────────────────────

def _version_comment(filename, version, timestamp):
    """Return the version stamp line for a given file type."""
    stamp = f"EDA Playground v{version} | {timestamp}"
    if filename.endswith((".sv", ".v", ".svh", ".vh")):
        return f"// {stamp}"
    elif filename.endswith(".md"):
        return f"<!-- {stamp} -->"
    else:
        return f"// {stamp}"


def _strip_version_stamp(content):
    """Remove existing version stamp from file content, return (stripped, old_version)."""
    # Match first line if it's a version stamp
    patterns = [
        r'^// EDA Playground v(\d+) \|.*\n?',
        r'^<!-- EDA Playground v(\d+) \|.*-->\n?',
    ]
    for pat in patterns:
        m = re.match(pat, content)
        if m:
            return content[m.end():], int(m.group(1))
    return content, 0


def add_version_stamp(filename, content):
    """Add/increment version stamp at top of file content."""
    stripped, old_version = _strip_version_stamp(content)
    new_version = old_version + 1
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    stamp_line = _version_comment(filename, new_version, timestamp)
    return f"{stamp_line}\n{stripped}", new_version


# ─── JS String Unescape (for pull) ──────────────────────────────────────────

def _unescape_js(s):
    s = s.replace("\\r\\n", "\n")
    s = s.replace("\\n", "\n")
    s = s.replace("\\r", "\n")
    s = s.replace("\\t", "\t")
    s = s.replace('\\"', '"')
    s = s.replace("\\'", "'")
    s = s.replace("\\/", "/")
    s = s.replace("\\\\", "\\")
    return s


# ─── Pull (no auth needed) ──────────────────────────────────────────────────

def cmd_pull(url, output_dir):
    """Download source files from an EDA Playground page."""
    print(f"Fetching: {url}")
    headers = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"}
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            html = resp.read().decode("utf-8", errors="replace")
    except (urllib.error.HTTPError, urllib.error.URLError) as e:
        print(f"Error fetching page: {e}", file=sys.stderr)
        sys.exit(1)

    files = {}
    for var_name in ["testbenchEditors", "designEditors"]:
        indices = set(re.findall(rf'{var_name}\[(\d+)\]', html))
        for idx in sorted(indices):
            name_match = re.search(rf'{var_name}\[{idx}\]\.name\s*=\s*"([^"]*)"', html)
            code_match = re.search(
                rf'{var_name}\[{idx}\]\.code\s*=\s*"(.*?)(?<!\\)";', html, re.DOTALL
            )
            if name_match and code_match:
                name = name_match.group(1)
                code = _unescape_js(code_match.group(1))
                if code.strip():
                    filename = name if "." in name else f"{name}.sv"
                    files[filename] = code

    if not files:
        print("No source files found. The playground may require login.", file=sys.stderr)
        sys.exit(1)

    os.makedirs(output_dir, exist_ok=True)
    print(f"Found {len(files)} file(s):")
    for filename, content in files.items():
        filepath = os.path.join(output_dir, filename)
        with open(filepath, "w") as f:
            f.write(content)
            if not content.endswith("\n"):
                f.write("\n")
        print(f"  {filepath}")
    print("Pull complete.")


# ─── Auth Helpers ────────────────────────────────────────────────────────────

def _ensure_playwright():
    try:
        from playwright.sync_api import sync_playwright
        return sync_playwright
    except ImportError:
        print("Playwright not installed. Run: pip install playwright && playwright install chromium",
              file=sys.stderr)
        sys.exit(1)


def _has_auth():
    return AUTH_FILE.exists() and AUTH_FILE.stat().st_size > 10


def _open_browser(sync_playwright_cls, headless=True):
    """Open browser with saved auth if available, otherwise headed for login."""
    pw = sync_playwright_cls().start()

    if _has_auth() and headless:
        browser = pw.chromium.launch(headless=True)
        context = browser.new_context(storage_state=str(AUTH_FILE))
    else:
        browser = pw.chromium.launch(headless=False)
        context = browser.new_context(
            storage_state=str(AUTH_FILE) if _has_auth() else None
        )

    return pw, browser, context


def _check_logged_in(page):
    """Check if the current page shows a logged-in session."""
    try:
        return page.evaluate(
            "() => !!document.getElementById('sessionUserId') && "
            "document.getElementById('sessionUserId').value !== ''"
        )
    except Exception:
        return False


def _wait_for_login(page, url):
    """Wait for the user to complete login, then save auth state."""
    print("\n*** Not logged in. Please log in via the browser window. ***")
    print("Waiting for login...")

    while True:
        page.wait_for_timeout(2000)
        try:
            if _check_logged_in(page):
                break
        except Exception:
            try:
                page.wait_for_load_state("domcontentloaded", timeout=30000)
            except Exception:
                pass

    # Save auth state
    page.context.storage_state(path=str(AUTH_FILE))
    print(f"Auth saved to {AUTH_FILE}")

    # Reload the target page
    print("Reloading playground...")
    page.goto(url, wait_until="networkidle")
    page.wait_for_timeout(2000)


def _navigate_and_auth(page, url):
    """Navigate to URL, handle login if needed, return when ready."""
    page.goto(url, wait_until="networkidle")

    if not _check_logged_in(page):
        # Reopen headed if we were headless
        _wait_for_login(page, url)

    # Update saved auth (refreshes token expiry)
    page.context.storage_state(path=str(AUTH_FILE))


# ─── Login Command ───────────────────────────────────────────────────────────

def cmd_login():
    """Interactive login — opens browser for Google auth, saves session."""
    sync_playwright = _ensure_playwright()
    pw, browser, context = _open_browser(sync_playwright, headless=False)

    page = context.new_page()
    page.goto("https://www.edaplayground.com/", wait_until="networkidle")

    if _check_logged_in(page):
        print("Already logged in!")
        context.storage_state(path=str(AUTH_FILE))
        print(f"Auth saved to {AUTH_FILE}")
    else:
        _wait_for_login(page, "https://www.edaplayground.com/")

    browser.close()
    pw.stop()
    print("Login complete.")


# ─── Editor Helpers ──────────────────────────────────────────────────────────

def _get_editor_map(page):
    """Get mapping of filenames to editor tab info from the page."""
    return page.evaluate("""() => {
        const map = {};
        if (typeof testbenchEditors !== 'undefined') {
            for (let i = 0; i < testbenchEditors.length; i++) {
                const name = testbenchEditors[i].name;
                const filename = name.includes('.') ? name : name + '.sv';
                map[filename] = { side: 'testbench', index: i, elemId: 'testbench' + i };
            }
        }
        if (typeof designEditors !== 'undefined') {
            for (let i = 0; i < designEditors.length; i++) {
                const name = designEditors[i].name;
                const filename = name.includes('.') ? name : name + '.sv';
                map[filename] = { side: 'design', index: i, elemId: 'design' + i };
            }
        }
        return map;
    }""")


def _set_editor_content(page, elem_id, side, content):
    """Set a CodeMirror editor's content via the global Tabs objects."""
    tabs_var = "testbenchTabs" if side == "testbench" else "designTabs"
    return page.evaluate(f"""(code) => {{
        try {{
            const tabs = (typeof {tabs_var} !== 'undefined') ? {tabs_var} : null;
            if (tabs && tabs.editors && tabs.editors['{elem_id}'] && tabs.editors['{elem_id}'].editor) {{
                tabs.editors['{elem_id}'].editor.getDoc().setValue(code);
                return true;
            }}
            return false;
        }} catch(e) {{ return false; }}
    }}""", content)


def _read_local_files(source_dir):
    """Read local source files, skipping tool scripts and dot files."""
    files = {}
    for fname in os.listdir(source_dir):
        fpath = os.path.join(source_dir, fname)
        if (os.path.isfile(fpath)
                and not fname.startswith(".")
                and fname not in SKIP_FILES):
            with open(fpath, "r") as f:
                files[fname] = f.read()
    return files


# ─── Push Command ────────────────────────────────────────────────────────────

def cmd_push(url, source_dir):
    """Push local files to EDA Playground."""
    local_files = _read_local_files(source_dir)
    if not local_files:
        print("No local files found to push.", file=sys.stderr)
        sys.exit(1)

    print(f"Local files: {', '.join(sorted(local_files.keys()))}")

    sync_playwright = _ensure_playwright()

    # Try headless first with saved auth
    headless = _has_auth()
    pw, browser, context = _open_browser(sync_playwright, headless=headless)
    page = context.new_page()

    try:
        page.goto(url, wait_until="networkidle")

        if not _check_logged_in(page):
            # Need to re-auth — close and reopen headed
            browser.close()
            pw.stop()
            pw, browser, context = _open_browser(sync_playwright, headless=False)
            page = context.new_page()
            _navigate_and_auth(page, url)

        editor_map = _get_editor_map(page)
        print(f"Remote tabs: {', '.join(sorted(editor_map.keys()))}")

        updated = []
        for filename, content in local_files.items():
            if filename not in editor_map:
                print(f"  Skipped: {filename} (no matching remote tab)")
                continue

            # Add version stamp
            stamped_content, version = add_version_stamp(filename, content)
            info = editor_map[filename]

            if _set_editor_content(page, info["elemId"], info["side"], stamped_content):
                updated.append(filename)
                print(f"  Updated: {filename} -> {info['elemId']} (v{version})")

                # Also update the local file with the version stamp
                with open(os.path.join(source_dir, filename), "w") as f:
                    f.write(stamped_content)
                    if not stamped_content.endswith("\n"):
                        f.write("\n")
            else:
                print(f"  FAILED: {filename} (editor not accessible)")

        if not updated:
            print("No files updated.")
            return False

        # Save
        page.locator("#saveButton").click()
        page.wait_for_timeout(3000)
        # Refresh auth
        context.storage_state(path=str(AUTH_FILE))
        print(f"Saved {len(updated)} file(s).")
        return True

    finally:
        if not headless:
            page.wait_for_timeout(2000)
        browser.close()
        pw.stop()


# ─── Run Command ─────────────────────────────────────────────────────────────

def cmd_run(url, log_file, page=None, owns_browser=True):
    """Run simulation on EDA Playground and download the log."""
    sync_playwright = _ensure_playwright()
    pw = browser = context = None

    if page is None:
        headless = _has_auth()
        pw, browser, context = _open_browser(sync_playwright, headless=headless)
        page = context.new_page()

        page.goto(url, wait_until="networkidle")

        if not _check_logged_in(page):
            browser.close()
            pw.stop()
            pw, browser, context = _open_browser(sync_playwright, headless=False)
            page = context.new_page()
            _navigate_and_auth(page, url)

        owns_browser = True

    try:
        # Click Run via JS to ensure it triggers reliably (headless or headed)
        print("Starting simulation...")
        page.evaluate("() => document.getElementById('runButton').click()")

        # Wait for simulation to start (codeRunning becomes '1')
        page.wait_for_timeout(2000)

        # Wait for completion — poll codeRunning flag and look for EXIT span
        print("Waiting for simulation to complete...")
        try:
            # Wait for the EXIT span which signals simulation finished
            page.locator("#results span.EXIT").wait_for(state="attached", timeout=SIM_TIMEOUT_MS)
        except Exception:
            # Fallback: check if codeRunning went back to 0
            still_running = page.evaluate(
                "() => document.getElementById('codeRunning') && "
                "document.getElementById('codeRunning').value === '1'"
            )
            if still_running:
                print("Simulation timed out!", file=sys.stderr)
                page.evaluate("() => { var s = document.getElementById('stopButton'); if (s) s.click(); }")
                page.wait_for_timeout(2000)

        # Let final results render
        page.wait_for_timeout(2000)

        # Capture log — get innerHTML and strip tags for clean text
        log_text = page.evaluate("""() => {
            const el = document.getElementById('results');
            if (!el) return '';
            // Get text content, replacing <br> with newlines
            const html = el.innerHTML;
            return html.replace(/<br\\s*\\/?>/gi, '\\n').replace(/<[^>]*>/g, '');
        }""")

        with open(log_file, "w") as f:
            f.write(log_text)
            if not log_text.endswith("\n"):
                f.write("\n")

        line_count = log_text.count("\n") + 1
        print(f"Simulation complete. Log saved to {log_file} ({line_count} lines)")

        # Check for errors
        has_errors = "UVM_ERROR" in log_text or "UVM_FATAL" in log_text or "Error" in log_text
        if has_errors:
            print("*** Errors detected in simulation log ***")

        # Refresh auth
        if context:
            context.storage_state(path=str(AUTH_FILE))

        return True

    finally:
        if owns_browser and browser:
            browser.close()
        if owns_browser and pw:
            pw.stop()


# ─── Push-Run Command ────────────────────────────────────────────────────────

def cmd_push_run(url, source_dir, log_file):
    """Push local files and immediately run the simulation in one browser session."""
    local_files = _read_local_files(source_dir)
    if not local_files:
        print("No local files found to push.", file=sys.stderr)
        sys.exit(1)

    print(f"Local files: {', '.join(sorted(local_files.keys()))}")

    sync_playwright = _ensure_playwright()

    headless = _has_auth()
    pw, browser, context = _open_browser(sync_playwright, headless=headless)
    page = context.new_page()

    try:
        page.goto(url, wait_until="networkidle")

        if not _check_logged_in(page):
            browser.close()
            pw.stop()
            pw, browser, context = _open_browser(sync_playwright, headless=False)
            page = context.new_page()
            _navigate_and_auth(page, url)

        # Push phase
        editor_map = _get_editor_map(page)
        print(f"Remote tabs: {', '.join(sorted(editor_map.keys()))}")

        updated = []
        for filename, content in local_files.items():
            if filename not in editor_map:
                print(f"  Skipped: {filename} (no matching remote tab)")
                continue

            stamped_content, version = add_version_stamp(filename, content)
            info = editor_map[filename]

            if _set_editor_content(page, info["elemId"], info["side"], stamped_content):
                updated.append(filename)
                print(f"  Updated: {filename} -> {info['elemId']} (v{version})")

                with open(os.path.join(source_dir, filename), "w") as f:
                    f.write(stamped_content)
                    if not stamped_content.endswith("\n"):
                        f.write("\n")
            else:
                print(f"  FAILED: {filename}")

        if not updated:
            print("No files updated. Skipping run.")
            return

        # Save
        print("Saving...")
        page.locator("#saveButton").click()
        page.wait_for_timeout(3000)
        print(f"Saved {len(updated)} file(s).")

        # Run phase
        cmd_run(url, log_file, page=page, owns_browser=False)

        # Refresh auth
        context.storage_state(path=str(AUTH_FILE))

    finally:
        browser.close()
        pw.stop()


# ─── CLI ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="EDA Playground CLI — pull, push, run simulations"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # login
    sub.add_parser("login", help="Interactive Google login, saves auth for reuse")

    # pull
    p_pull = sub.add_parser("pull", help="Download source files from EDA Playground")
    p_pull.add_argument("url", help="EDA Playground URL")
    p_pull.add_argument("--output-dir", default=".", help="Output directory (default: .)")

    # push
    p_push = sub.add_parser("push", help="Upload local files to EDA Playground")
    p_push.add_argument("url", help="EDA Playground URL")
    p_push.add_argument("--source-dir", default=".", help="Source directory (default: .)")

    # run
    p_run = sub.add_parser("run", help="Run simulation and download log")
    p_run.add_argument("url", help="EDA Playground URL")
    p_run.add_argument("--log-file", default="sim.log", help="Log output file (default: sim.log)")

    # push-run
    p_pr = sub.add_parser("push-run", help="Push files then run simulation")
    p_pr.add_argument("url", help="EDA Playground URL")
    p_pr.add_argument("--source-dir", default=".", help="Source directory (default: .)")
    p_pr.add_argument("--log-file", default="sim.log", help="Log output file (default: sim.log)")

    args = parser.parse_args()

    if args.command == "login":
        cmd_login()
    elif args.command == "pull":
        cmd_pull(args.url, args.output_dir)
    elif args.command == "push":
        cmd_push(args.url, args.source_dir)
    elif args.command == "run":
        cmd_run(args.url, args.log_file)
    elif args.command == "push-run":
        cmd_push_run(args.url, args.source_dir, args.log_file)


if __name__ == "__main__":
    main()
