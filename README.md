# CRC-24/BLE UVM Verification Project

UVM testbench for a CRC-24/BLE hardware engine — the CRC used in every Bluetooth Low Energy packet.

## What's here

| File | Description |
|------|-------------|
| `design.sv` | CRC-24/BLE RTL module with 3 SVA assertions |
| `testbench.sv` | Complete UVM testbench (single file — see [architecture](uvm_tb_arch.md)) |
| `test_plan.md` | Verification plan: directed tests, randomization, coverage targets |
| `uvm_tb_arch.md` | UVM component hierarchy, sequences, coverage model, portability |
| `tools/eda_playground.py` | EDA Playground automation script (pull, push, run, log capture) |
| `tools/SKILL.md` | Claude Code skill definition — install to teach Claude the workflow |

## Quick start

### Run on EDA Playground

The testbench runs on [EDA Playground](https://www.edaplayground.com/x/tvdd) with VCS or Xcelium — no local simulator needed.

### Run from Claude Code

The `tools/eda_playground.py` script automates EDA Playground via Playwright browser automation, giving you an edit-push-run-debug loop without leaving the terminal. It effectively gives you VCS access locally.

#### Install the Claude Code skill

The EDA Playground skill teaches Claude how to use the automation script automatically. Install it once and Claude will know how to pull, push, run, and debug whenever you mention EDA Playground.

**Prerequisites:**
```bash
pip install playwright && playwright install chromium
```

**Install the skill:**
```bash
# Create the skill directory
mkdir -p ~/.claude/skills/eda-playground/scripts

# Copy the skill definition
cp tools/SKILL.md ~/.claude/skills/eda-playground/SKILL.md

# Copy the automation script
cp tools/eda_playground.py ~/.claude/skills/eda-playground/scripts/eda_playground.py
```

**One-time auth setup:**
```bash
# Opens a browser — log in with your Google account
python3 ~/.claude/skills/eda-playground/scripts/eda_playground.py login
```

This saves your session to `~/.eda-playground-auth.json`. You won't need to log in again unless the session expires.

**That's it.** Now in Claude Code you can say things like:
- "pull the files from https://www.edaplayground.com/x/tvdd"
- "push my changes and run the sim"
- "check the sim log for errors"
- "fix the testbench and re-run"

Claude will use the skill to run the right commands automatically.

#### Manual usage (without the skill)

You can also run the script directly:

```bash
# Pull source files from a playground
python3 tools/eda_playground.py pull https://www.edaplayground.com/x/tvdd

# Edit files locally, then push changes and run the sim
python3 tools/eda_playground.py push-run https://www.edaplayground.com/x/tvdd

# Check the log
cat sim.log | grep -E "PASS|FAIL|SUMMARY"
```

The typical workflow:

1. **Pull** files from EDA Playground
2. **Edit** locally (Claude can read the sim log and fix bugs)
3. **Push + Run** uploads changes, runs VCS, downloads the log
4. **Debug** — read `sim.log`, fix, repeat

Each push adds a version stamp (`// EDA Playground v5 | 2026-03-18 ...`) so you can verify the upload took effect on the website.

See `tools/eda_playground.py --help` for all commands.

### Run with a local simulator

```bash
# VCS
vcs -sverilog -ntb_opts uvm design.sv testbench.sv +UVM_TESTNAME=crc24_full_test && ./simv

# Questa
vlog -sv design.sv testbench.sv && vsim tb_top +UVM_TESTNAME=crc24_full_test

# Xcelium
xrun -sv -uvm design.sv testbench.sv +UVM_TESTNAME=crc24_full_test
```

Available tests: `crc24_base_test`, `crc24_smoke_test`, `crc24_directed_test`, `crc24_full_test`

## DUT

The CRC-24/BLE module (`design.sv`) computes the 24-bit CRC defined by the Bluetooth Core Specification:

- **Polynomial**: x^24 + x^10 + x^9 + x^6 + x^4 + x^3 + x + 1 (0x00065B, reflected: 0xDA6000)
- **Processing**: LSB-first, one byte per clock cycle
- **Init seed**: Configurable via `crc_init` / `start` signal (BLE default: 0x555555)
- **Interface**: `data_in[7:0]` + `data_valid` in, `crc_out[23:0]` + `crc_valid` out

Three SVA assertions are embedded in the DUT:
1. `crc_valid` asserts exactly 1 cycle after `data_valid`
2. No X/Z on `crc_out` while `crc_valid` is high
3. `crc_out` must be 0x000000 during reset

## Verification results

The `crc24_full_test` runs 104 transactions across 6 phases:

| Metric | Result |
|--------|--------|
| Scoreboard | 103/104 pass |
| cp_pkt_len | 100% |
| cp_data_in | 100% |
| cp_init | 100% |
| cx_data_pktlen | 100% |
| cx_pkt_len_init | 100% |

The 1 remaining failure is a known testbench limitation in the mid-transaction reset test (Phase 5) — the DUT clears `crc_out` before the monitor can capture it. This is a monitor timing edge case, not a DUT bug.

## Project docs

- **[uvm_tb_arch.md](uvm_tb_arch.md)** — Testbench architecture: component hierarchy, class catalog, sequences, coverage model, portability patterns, and the single-file packaging rationale
- **[test_plan.md](test_plan.md)** — Verification plan: what to test, how to test it, pass/fail criteria, and current status

## Built with

- DUT and testbench iterated with Claude (Anthropic)
- Test plan originated from ChatGPT, refined during implementation
- EDA Playground automation via Playwright
- Runs on Synopsys VCS via EDA Playground
