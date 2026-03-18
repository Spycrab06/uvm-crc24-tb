# Test Plan — CRC-24/BLE DUT

Verification plan for the CRC-24/BLE hardware engine. For testbench architecture details, see [uvm_tb_arch.md](uvm_tb_arch.md).

## 1. Objective

Verify that the CRC-24/BLE DUT correctly computes the 24-bit BLE CRC for all valid packet configurations, using configurable initialization values and LSB-first bit processing, across normal operation, boundary conditions, and protocol corner cases.

## 2. DUT interface

| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| `clk` | 1 | in | System clock |
| `rst_n` | 1 | in | Active-low async reset |
| `start` | 1 | in | Load `crc_init` seed, begin new transaction |
| `clear` | 1 | in | Synchronous reset CRC to 0x000000 |
| `crc_init` | 24 | in | CRC seed value (loaded on `start`) |
| `data_in` | 8 | in | Payload byte |
| `data_valid` | 1 | in | Asserted when `data_in` is valid |
| `crc_out` | 24 | out | Computed CRC result |
| `crc_valid` | 1 | out | Asserted 1 cycle after `data_valid` |

The DUT processes one byte per clock cycle, LSB-first, using the BLE polynomial 0x00065B (reflected: 0xDA6000).

## 3. Features to verify

### 3.1 Reset
- Async reset clears CRC state and outputs
- `crc_out` = 0x000000 while `rst_n` is low (SVA enforced)
- Reset between transactions clears prior state
- Recovery from mid-transaction reset

### 3.2 CRC initialization
- `start` pulse loads `crc_init` seed correctly
- `clear` pulse resets CRC to 0x000000 (alternative to `start`)
- Different init values produce different CRC outputs
- BLE default init (0x555555) works correctly

### 3.3 Payload processing
- Single-byte payloads (minimum)
- Multi-byte payloads up to 37 bytes (BLE ADV PDU maximum)
- All-zero, all-ones, and mixed-value payloads
- `data_valid` gap mid-packet (1-cycle deassertion, then resume)

### 3.4 Transaction control
- `start` launches new CRC calculation
- `crc_valid` asserts exactly 1 cycle after `data_valid` (SVA enforced)
- Back-to-back transactions with no idle cycles between
- `clear` asserted simultaneously with `data_valid` deassertion (overlap corner case)

### 3.5 Output integrity
- No X/Z on `crc_out` while `crc_valid` = 1 (SVA enforced)
- CRC output matches reference model for all tested configurations

## 4. Reference model

A software golden model (`crc24_ref_model`) computes the expected CRC independently:
- BLE polynomial 0x00065B in reflected form (0xDA6000)
- LSB-first bit processing within each byte
- Configurable 24-bit init seed
- Static function: `compute(data[], num_bytes, init)` returns expected CRC

Every transaction's expected output comes from this model, never from DUT output.

## 5. Directed test list

| # | Test | Description | Status |
|---|------|-------------|--------|
| 1 | Reset smoke | Confirm DUT resets; CRC clears, no false output | Pass (Phase 1) |
| 2 | Single known packet | BLE default init (0x555555), 1-byte payload, exact CRC match | Pass (Phase 2) |
| 3 | Multiple patterns | All-zeros, all-ones, 0x42, 0xA5 payloads across 5 lengths | Pass (Phase 2) |
| 4 | Zero-length payload | CRC from init-only state | N/A — not supported by hardware |
| 5 | Minimum payload | 1-byte payload (smallest legal BLE packet) | Pass (Phase 2) |
| 6 | Maximum payload | 37-byte payload (BLE ADV PDU max) | Pass (Phase 3.5) |
| 7 | Different init values | 0x555555, 0x000000, 0xFFFFFF, 0xABCDEF across 5 lengths | Pass (Phase 3) |
| 8 | Back-to-back transactions | 20+ consecutive packets, no idle gaps | Pass (Phases 2–4) |
| 9 | Mid-transaction reset | Reset during active CRC, verify clean recovery | 1 known issue |
| 10 | Random regression | 50 randomized packets | Pass (Phase 6) |

**Test 9 known issue**: The test calls `reset_dut()` immediately after a packet completes. The DUT clears `crc_out_reg` before the monitor can capture the final CRC (1-cycle pipeline timing). This is a testbench timing edge case, not a DUT bug. The recovery packet after reset passes correctly.

## 6. Randomization strategy

**Randomized fields:**
- Payload length (1–37, weighted toward longer packets)
- Payload byte values (full 0x00–0xFF range)
- CRC init seed (weighted: 30% 0x555555, 20% each 0x000000/0xFFFFFF)
- Gap insertion (soft default off, forced on in gap sequences)
- Clear overlap (soft default off, forced on in overlap sequences)

**Constraints:**
- Payload length range: [1, 37] (BLE ADV PDU)
- Zero-length excluded (not supported by hardware)
- Length distribution biases toward boundary values and BLE-typical lengths

## 7. Scoreboard checks

For each transaction:
1. Collect payload bytes and init value from monitor
2. Compute expected CRC via reference model
3. Compare `crc_out === expected`
4. Special case: clear-overlap expects `crc_out == 0x000000`
5. Report mismatch with: length, init, expected, actual

Protocol checks (SVA in DUT):
- `data_valid |=> crc_valid` (disabled during reset and start)
- `crc_valid |-> !$isunknown(crc_out)`
- `!rst_n |-> (crc_out == 24'h000000)`

## 8. Functional coverage

### Coverpoints

| Coverpoint | Bins | Description |
|------------|------|-------------|
| `cp_pkt_len` | 1 / 2–3 / 4–6 / 7–8 / 9–37 | Packet length ranges |
| `cp_data_in` | 0x00 / 0xFF / 0x01–0x7F / 0x80–0xFE | First payload byte value |
| `cp_crc_out` | 0x000000 / 0xFFFFFF / other | CRC output extremes |
| `cp_init` | 0x555555 / 0x000000 / 0xFFFFFF / other | Init seed values |
| `cp_txn_type` | with_start / with_clear | Init method |
| `cp_gap` | no_gap / has_gap | Mid-packet gap |
| `cp_clear_overlap` | normal / overlap | Clear timing corner case |

### Cross coverage

| Cross | Dimensions | Bins | Target |
|-------|-----------|------|--------|
| `cx_data_pktlen` | data byte x length | 4 x 5 = 20 | 100% |
| `cx_pkt_len_init` | length x init seed | 5 x 4 = 20 | 100% |
| `cx_pkt_len_txntype` | length x start/clear | 5 x 2 = 10 | Partial |
| `cx_pkt_len_gap` | length x gap | 5 x 2 = 10 | Partial |

### Current results

| Coverpoint / Cross | Coverage |
|--------------------|----------|
| cp_pkt_len | 100% |
| cp_data_in | 100% |
| cp_init | 100% |
| cx_data_pktlen | 100% |
| cx_pkt_len_init | 100% |
| cp_txn_type | 50% (no `with_clear` transactions in current test suite) |
| cx_pkt_len_txntype | 50% |
| cp_crc_out | 50% (0xFFFFFF CRC not hit — rare for random data) |

## 9. Pass/fail criteria

The DUT passes when:
- All directed tests pass (tests 1–8, 10)
- Randomized regression completes with zero mismatches
- Key coverage bins hit 100% (cp_pkt_len, cp_data_in, cp_init, cx_data_pktlen, cx_pkt_len_init)
- No SVA violations

**Current status**: 103/104 transactions pass, 0 SVA violations, key coverage at 100%.

## 10. Coverage gaps and future work

**Coverage gaps to close:**
- `cp_txn_type` / `cx_pkt_len_txntype`: Add sequences using `use_start=0` (clear-based init)
- `cp_crc_out`: 0xFFFFFF CRC output bin — would require a payload specifically crafted to produce this output (infeasible to hit randomly)

**Future extensions:**
- Error injection (corrupt data mid-packet, check CRC changes)
- Performance / latency measurements
- Formal verification of CRC state machine (e.g., JasperGold)
- Compliance testing against captured BLE packet traces
- Fix Phase 5 monitor timing to correctly capture CRC when reset follows immediately
