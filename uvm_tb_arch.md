# UVM Testbench Architecture — CRC-24/BLE

This document describes the UVM testbench implementation in `testbench.sv`. Everything — interface, package, all UVM classes, and the top-level module — lives in a single file for EDA Playground compatibility. In a real project these would be split across files, but the architecture is the same.

## Component hierarchy

```
tb_top (module)
├── clk                          100 MHz clock generator
├── crc24_if vif                 Interface instance
├── crc24 dut                    DUT instance
└── UVM
    └── crc24_full_test          (or smoke_test, directed_test)
        └── crc24_env
            ├── crc24_agent
            │   ├── crc24_driver        [UVM_ACTIVE only]
            │   ├── uvm_sequencer       [UVM_ACTIVE only]
            │   └── crc24_monitor       [always]
            │       └── ap ──────┐
            ├── crc24_scoreboard ◄──── analysis port
            └── crc24_coverage   ◄──── analysis port
```

Data flow: **sequence → sequencer → driver → DUT pins → monitor → {scoreboard, coverage}**

## Interface — `crc24_if`

Bundles all DUT signals with two clocking blocks for proper driver/monitor timing.

| Signal | Width | Description |
|--------|-------|-------------|
| `clk` | 1 | System clock (input to interface) |
| `rst_n` | 1 | Active-low async reset |
| `start` | 1 | Load `crc_init` and begin new transaction |
| `clear` | 1 | Synchronous reset CRC to 0x000000 |
| `crc_init` | 24 | CRC seed loaded on `start` |
| `data_in` | 8 | Payload byte |
| `data_valid` | 1 | Asserted when `data_in` is valid |
| `crc_out` | 24 | Computed CRC output |
| `crc_valid` | 1 | Asserted 1 cycle after last `data_valid` |

**Clocking blocks:**

| Block | Used by | Timing | Purpose |
|-------|---------|--------|---------|
| `drv_cb` | Driver | input #1step, output #0 | Drive DUT inputs, sample outputs |
| `mon_cb` | Monitor | input #1step | Passive observation only |

Modports `DRV` and `MON` enforce the driver/monitor roles.

## Class catalog

### crc24_seq_item

Transaction object. Stimulus fields are randomizable; observation fields are populated by the monitor.

**Stimulus fields:**
- `rand logic [7:0] payload[]` — Dynamic byte array
- `rand int unsigned payload_len` — 1–37 bytes (BLE ADV PDU range)
- `rand logic [23:0] crc_init` — CRC seed
- `rand bit use_start` — 1 = load seed via `start`; 0 = use `clear`
- `rand bit insert_gap` — 1 = drop `data_valid` for 1 cycle mid-packet
- `rand bit assert_clear_overlap` — 1 = assert `clear` when `data_valid` drops

**Observation fields:**
- `logic [23:0] crc_out` — DUT's CRC result
- `bit crc_valid` — CRC valid flag

**Key constraints:**
- `c_len`: `payload.size() == payload_len`, range [1:37]
- `c_len_dist`: Weighted toward longer packets (9–37 bytes = 40%)
- `c_init_dist`: 30% BLE default 0x555555, 20% each for 0x000000/0xFFFFFF
- `c_defaults`: Soft defaults (use_start=1, no gap, no clear overlap)

### crc24_ref_model

Pure-function golden model. Static method `compute(data[], num_bytes, init)` returns the expected CRC. Uses the reflected BLE polynomial 0xDA6000 with LSB-first bit processing. Called by the scoreboard for every transaction.

### crc24_driver

Converts `crc24_seq_item` transactions into pin-level activity:

1. **Init phase**: Assert `start` for 1 cycle (loading `crc_init`), or assert `clear` for 1 cycle
2. **Data phase**: Drive `data_in` + `data_valid` for each payload byte. If `insert_gap`, deassert `data_valid` for 1 cycle at the midpoint
3. **End phase**: Deassert `data_valid`. If `assert_clear_overlap`, simultaneously assert `clear`

Also exposes `reset_dut(cycles)` task, called directly by tests.

### crc24_monitor

Passively reconstructs transactions from interface observations. Key design features:

- **X-value safety**: Waits until `rst_n === 1'b1` before processing (avoids phantom transactions from simulation-start X values)
- **Gap detection**: 1-cycle lookahead when `data_valid` drops. If it recovers next cycle, it was a gap — keep collecting. If it stays low, end of packet
- **Back-to-back optimization**: When capturing `crc_out`, also checks if the next transaction's `start` is already asserted. Saves `crc_init` in `saw_start`/`saved_crc_init` to avoid missing the start pulse
- **crc_out capture**: Happens naturally at the end of the lookahead (1 cycle after `data_valid` drops), which aligns with the DUT's pipeline delay

Broadcasts completed `crc24_seq_item` objects via analysis port.

### crc24_scoreboard

Receives transactions from the monitor's analysis port. For each:

1. Derives init: `use_start ? crc_init : 24'h000000`
2. Calls `crc24_ref_model::compute()` for expected CRC
3. **Clear-overlap case**: Expects `crc_out == 0x000000` (DUT zeros CRC on clear)
4. **Normal case**: Compares `crc_out === expected`
5. Reports pass/fail with payload details; prints summary in `report_phase`

### crc24_coverage

Separate `uvm_subscriber` (not part of scoreboard — UVM best practice). Samples transaction-level fields, not raw signals, so it works at any integration level.

**7 coverpoints:**

| Coverpoint | Bins |
|------------|------|
| `cp_pkt_len` | single_byte(1), short(2–3), mid(4–6), long(7–8), ble_adv(9–37) |
| `cp_data_in` | all_zeros(0x00), all_ones(0xFF), low(0x01–0x7F), high(0x80–0xFE) |
| `cp_crc_out` | zero(0x000000), ones(0xFFFFFF), others |
| `cp_init` | ble_default(0x555555), zeros, ones, others |
| `cp_txn_type` | with_start, with_clear |
| `cp_gap` | no_gap, has_gap |
| `cp_clear_overlap` | normal, overlap |

**4 cross coverages:**

| Cross | Dimensions | Bins |
|-------|-----------|------|
| `cx_data_pktlen` | data byte x pkt length | 4 x 5 = 20 |
| `cx_pkt_len_init` | pkt length x init seed | 5 x 4 = 20 |
| `cx_pkt_len_txntype` | pkt length x start/clear | 5 x 2 = 10 |
| `cx_pkt_len_gap` | pkt length x gap | 5 x 2 = 10 |

### crc24_agent

Standard UVM agent with active/passive support:

- **UVM_ACTIVE** (unit level): Instantiates driver + sequencer + monitor. Driver connected to sequencer via `seq_item_port`
- **UVM_PASSIVE** (system level): Monitor only. Agent can be embedded as sub-component in a system-level env where something else drives the DUT

Forwards `monitor.ap` as `agent.ap` for convenient connection.

### crc24_env

Top-level environment. Config knobs via `uvm_config_db`:

| Knob | Type | Default | Effect |
|------|------|---------|--------|
| `has_scoreboard` | bit | 1 | Instantiate scoreboard |
| `has_coverage` | bit | 1 | Instantiate coverage |

Connects `agent.ap` to scoreboard and coverage analysis exports.

## Sequences

| Sequence | Transactions | Purpose |
|----------|-------------|---------|
| `crc24_base_seq` | 1 random | Building block |
| `crc24_zeros_seq` | 1 (all-0x00 payload, configurable length) | Edge case |
| `crc24_ones_seq` | 1 (all-0xFF payload, configurable length) | Edge case |
| `crc24_ble_init_seq` | 1 (random payload, init=0x555555) | BLE compliance |
| `crc24_gap_seq` | 1 (insert_gap=1, len >= 4) | Protocol corner case |
| `crc24_clear_overlap_seq` | 1 (clear during data_valid deassert) | Corner case |
| `crc24_cross_coverage_seq` | 20 (4 data vals x 5 lengths) | Hit cx_data_pktlen |
| `crc24_init_cross_seq` | 20 (4 inits x 5 lengths) | Hit cx_pkt_len_init |
| `crc24_random_seq` | N (default 50) | Regression |

## Tests

| Test | Phases | Total txns |
|------|--------|-----------|
| `crc24_base_test` | Reset only | 0 |
| `crc24_smoke_test` | Reset, 1-byte zeros, 1-byte ones | 2 |
| `crc24_directed_test` | Reset, cross coverage, init cross, gaps, clear overlap | ~48 |
| `crc24_full_test` | All of directed + BLE init + mid-reset + 50 random | ~104 |

### crc24_full_test phases

1. **Reset** — `reset_dut(4)`, 4-cycle async reset
2. **Directed cross-coverage** — `crc24_cross_coverage_seq` (20 txns)
3. **Init seed coverage** — `crc24_init_cross_seq` (20 txns)
4. **BLE init** — `crc24_ble_init_seq` x 5
5. **Corner cases** — `crc24_gap_seq` x 5, `crc24_clear_overlap_seq` x 3
6. **Mid-transaction reset** — 1 packet, reset, 1 recovery packet
7. **Random regression** — `crc24_random_seq` (50 txns)

## Portability

The testbench is designed for reuse at both unit and system level:

**Unit level** (current usage):
```systemverilog
// tb_top instantiates DUT + interface, agent is UVM_ACTIVE
run_test(); // +UVM_TESTNAME=crc24_full_test
```

**System level** (integration):
```systemverilog
class soc_env extends uvm_env;
  crc24_env crc_sub_env;

  function void build_phase(uvm_phase phase);
    // Set passive — system-level driver handles stimulus
    uvm_config_db#(uvm_active_passive_enum)::set(
      this, "crc_sub_env.agent", "is_active", UVM_PASSIVE);
    crc_sub_env = crc24_env::type_id::create("crc_sub_env", this);
  endfunction
endclass
```

The monitor, scoreboard, and coverage work identically in both modes — they observe transactions, not stimulus source.

## Single-file packaging

Everything is in one `testbench.sv` for EDA Playground compatibility:

```
testbench.sv
├── `timescale 1ns/1ps
├── interface crc24_if              (outside package)
├── package crc24_pkg
│   ├── crc24_seq_item
│   ├── crc24_ref_model
│   ├── crc24_driver
│   ├── crc24_monitor
│   ├── crc24_scoreboard
│   ├── crc24_coverage
│   ├── crc24_agent
│   ├── crc24_env
│   ├── 9 sequence classes
│   └── 4 test classes
└── module tb_top                   (outside package)
    ├── clock gen
    ├── interface instance
    ├── DUT instance
    ├── config_db setup
    └── run_test()
```

In a multi-file project, each class would be its own `.svh` file included from the package.
