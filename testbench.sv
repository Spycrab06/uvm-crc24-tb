// ============================================================
//  crc24_uvm_tb.sv -- CRC-24/BLE UVM Testbench (Single File)
//
//  NOTE: This file combines what would normally be separate
//  files into one compilation unit for easier management on
//  EDA Playground, which has limited tab/file support.
//
//  In a normal project structure, split as:
//
//    crc24_pkg/
//      crc24_if.sv              -- Interface + clocking blocks
//      crc24_pkg.sv             -- Package header (imports, includes)
//      crc24_seq_item.svh       -- Transaction object
//      crc24_ref_model.svh      -- CRC-24 golden reference model
//      crc24_driver.svh         -- Pin-level driver
//      crc24_monitor.svh        -- Passive transaction monitor
//      crc24_scoreboard.svh     -- Reference model comparison
//      crc24_coverage.svh       -- Functional coverage collector
//      crc24_agent.svh          -- Agent (driver + monitor + sequencer)
//      crc24_env.svh            -- Environment (agent + scoreboard + coverage)
//      crc24_sequences.svh      -- All sequence classes
//      crc24_tests.svh          -- All test classes
//    tb/
//      tb_top.sv                -- Top module (clock, DUT, UVM launch)
//
//  COMPILE & RUN:
//    VCS:     vcs -sverilog -ntb_opts uvm design.sv testbench.sv +UVM_TESTNAME=crc24_full_test
//    Questa:  vlog -sv design.sv testbench.sv && vsim tb_top +UVM_TESTNAME=crc24_full_test
//    Xcelium: xrun -sv -uvm design.sv testbench.sv +UVM_TESTNAME=crc24_full_test
//
//  PORTABILITY:
//    Unit level  -> agent is UVM_ACTIVE (driver + sequencer + monitor)
//    System level -> set agent to UVM_PASSIVE (monitor only);
//                   instantiate crc24_env as a sub-env in your
//                   system-level environment.
// ============================================================

`timescale 1ns/1ps

// ============================================================
//  INTERFACE -- bundles all DUT signals with clocking blocks
// ============================================================
interface crc24_if (input logic clk);
  logic        rst_n;
  logic        start;
  logic        clear;
  logic [23:0] crc_init;
  logic [7:0]  data_in;
  logic        data_valid;
  logic [23:0] crc_out;
  logic        crc_valid;

  // Clocking blocks enforce proper driver/monitor timing
  clocking drv_cb @(posedge clk);
    default input #1step output #0;
    output rst_n, start, clear, crc_init, data_in, data_valid;
    input  crc_out, crc_valid;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step output #0;
    input rst_n, start, clear, crc_init, data_in, data_valid;
    input crc_out, crc_valid;
  endclocking

  modport DRV (clocking drv_cb);
  modport MON (clocking mon_cb);
endinterface


// ============================================================
//  PACKAGE -- all UVM classes
// ============================================================
package crc24_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // ==========================================================
  //  SEQUENCE ITEM -- transaction object
  // ==========================================================
  class crc24_seq_item extends uvm_sequence_item;

    // --- Stimulus fields (randomizable) ---
    rand logic [7:0]  payload[];
    rand int unsigned  payload_len;
    rand logic [23:0]  crc_init;
    rand bit           use_start;             // 1 = load crc_init via start; 0 = use clear
    rand bit           insert_gap;            // 1 = insert 1-cycle data_valid gap mid-packet
    rand bit           assert_clear_overlap;  // 1 = assert clear when data_valid deasserts

    // --- Observed fields (populated by monitor) ---
    logic [23:0] crc_out;
    bit          crc_valid;

    // --- Constraints ---
    constraint c_len {
      payload_len inside {[1:37]};
      payload.size() == payload_len;
    }

    constraint c_len_dist {
      payload_len dist {
        1       := 15,
        [2:3]   := 15,
        [4:6]   := 15,
        [7:8]   := 15,
        [9:37]  := 40
      };
    }

    constraint c_init_dist {
      crc_init dist {
        24'h555555 := 30,
        24'h000000 := 20,
        24'hFFFFFF := 20,
        [24'h000001:24'h555554] := 15,
        [24'h555556:24'hFFFFFE] := 15
      };
    }

    constraint c_defaults {
      soft use_start == 1;
      soft insert_gap == 0;
      soft assert_clear_overlap == 0;
    }

    `uvm_object_utils_begin(crc24_seq_item)
      `uvm_field_array_int(payload, UVM_ALL_ON)
      `uvm_field_int(payload_len, UVM_ALL_ON)
      `uvm_field_int(crc_init, UVM_ALL_ON)
      `uvm_field_int(use_start, UVM_ALL_ON)
      `uvm_field_int(insert_gap, UVM_ALL_ON)
      `uvm_field_int(assert_clear_overlap, UVM_ALL_ON)
      `uvm_field_int(crc_out, UVM_ALL_ON | UVM_NOCOMPARE)
      `uvm_field_int(crc_valid, UVM_ALL_ON | UVM_NOCOMPARE)
    `uvm_object_utils_end

    function new(string name = "crc24_seq_item");
      super.new(name);
    endfunction

    function string convert2string();
      return $sformatf("len=%0d init=0x%06h start=%0b gap=%0b clr_ovlp=%0b crc_out=0x%06h",
                       payload_len, crc_init, use_start, insert_gap,
                       assert_clear_overlap, crc_out);
    endfunction

  endclass


  // ==========================================================
  //  REFERENCE MODEL -- CRC-24/BLE golden model
  //
  //  BLE polynomial: x^24+x^10+x^9+x^6+x^4+x^3+x+1 = 0x00065B
  //  Reflected for LSB-first processing: 0xDA6000
  // ==========================================================
  class crc24_ref_model extends uvm_object;
    `uvm_object_utils(crc24_ref_model)

    localparam logic [23:0] POLY = 24'hDA6000;

    function new(string name = "crc24_ref_model");
      super.new(name);
    endfunction

    static function logic [23:0] compute(
      logic [7:0]  data[],
      int          num_bytes,
      logic [23:0] init = 24'h000000
    );
      logic [23:0] crc;
      logic        feedback;

      crc = init;
      for (int i = 0; i < num_bytes; i++) begin
        for (int b = 0; b < 8; b++) begin
          feedback = data[i][b] ^ crc[0];
          crc >>= 1;
          if (feedback) crc ^= POLY;
        end
      end
      return crc;
    endfunction

  endclass


  // ==========================================================
  //  DRIVER -- converts seq_items to pin-level activity
  // ==========================================================
  class crc24_driver extends uvm_driver #(crc24_seq_item);
    `uvm_component_utils(crc24_driver)

    virtual crc24_if vif;

    function new(string name = "crc24_driver", uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual crc24_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "Virtual interface not found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
      crc24_seq_item req;

      // Initialize outputs
      vif.drv_cb.rst_n       <= 1'b1;
      vif.drv_cb.start       <= 1'b0;
      vif.drv_cb.clear       <= 1'b0;
      vif.drv_cb.data_valid  <= 1'b0;
      vif.drv_cb.data_in     <= 8'h00;
      vif.drv_cb.crc_init    <= 24'h000000;

      forever begin
        seq_item_port.get_next_item(req);
        drive_item(req);
        seq_item_port.item_done();
      end
    endtask

    task drive_item(crc24_seq_item item);
      int gap_at;

      // --- Start / Init ---
      if (item.use_start) begin
        vif.drv_cb.crc_init <= item.crc_init;
        vif.drv_cb.start    <= 1'b1;
        @(vif.drv_cb);
        vif.drv_cb.start    <= 1'b0;
      end else begin
        vif.drv_cb.clear <= 1'b1;
        @(vif.drv_cb);
        vif.drv_cb.clear <= 1'b0;
      end

      // --- Payload bytes ---
      gap_at = item.payload_len / 2;
      foreach (item.payload[i]) begin
        vif.drv_cb.data_in    <= item.payload[i];
        vif.drv_cb.data_valid <= 1'b1;
        @(vif.drv_cb);

        // Optional 1-cycle gap mid-packet
        if (item.insert_gap && i == gap_at) begin
          vif.drv_cb.data_valid <= 1'b0;
          @(vif.drv_cb);
        end
      end

      // --- End of packet ---
      if (item.assert_clear_overlap) begin
        vif.drv_cb.data_valid <= 1'b0;
        vif.drv_cb.clear      <= 1'b1;
        @(vif.drv_cb);
        vif.drv_cb.clear      <= 1'b0;
        @(vif.drv_cb);
      end else begin
        vif.drv_cb.data_valid <= 1'b0;
        @(vif.drv_cb);
      end

      `uvm_info("DRV", $sformatf("Drove: %s", item.convert2string()), UVM_HIGH)
    endtask

    task reset_dut(int unsigned cycles = 2);
      vif.drv_cb.rst_n      <= 1'b0;
      vif.drv_cb.data_valid <= 1'b0;
      vif.drv_cb.start      <= 1'b0;
      vif.drv_cb.clear      <= 1'b0;
      repeat (cycles) @(vif.drv_cb);
      vif.drv_cb.rst_n      <= 1'b1;
      @(vif.drv_cb);
    endtask

  endclass


  // ==========================================================
  //  MONITOR -- passively observes interface, reconstructs txns
  //
  //  PORTABILITY: purely passive -- works identically at unit
  //  and system level.
  // ==========================================================
  class crc24_monitor extends uvm_monitor;
    `uvm_component_utils(crc24_monitor)

    virtual crc24_if vif;

    uvm_analysis_port #(crc24_seq_item) ap;

    function new(string name = "crc24_monitor", uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      ap = new("ap", this);
      if (!uvm_config_db#(virtual crc24_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "Virtual interface not found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
      fork
        monitor_transactions();
      join
    endtask

    task monitor_transactions();
      crc24_seq_item txn;
      logic [7:0] pkt_bytes[$];
      bit          saw_start;
      logic [23:0] saved_crc_init;

      saw_start = 0;

      forever begin
        // If we already captured a start pulse while reading crc_out,
        // skip the idle wait -- we're already synchronized.
        if (!saw_start) begin
          @(vif.mon_cb);
          // Skip until rst_n is definitively high (handles X at sim start)
          if (vif.mon_cb.rst_n !== 1'b1) continue;
          if (!(vif.mon_cb.start || vif.mon_cb.data_valid))
            continue;
        end

        txn = crc24_seq_item::type_id::create("txn");

        // Capture init value if start is (or was) asserted
        if (saw_start || vif.mon_cb.start) begin
          txn.crc_init  = saw_start ? saved_crc_init : vif.mon_cb.crc_init;
          txn.use_start = 1;
          saw_start = 0;
          @(vif.mon_cb); // Wait for start to deassert
        end else begin
          txn.crc_init  = 24'h000000;
          txn.use_start = 0;
        end

        // Collect payload bytes with gap handling.
        // A gap is a 1-cycle dip in data_valid mid-packet. We use a
        // 1-cycle lookahead: when data_valid drops, peek at the next
        // cycle. If data_valid returns, it was a gap; if not, the
        // packet has ended and crc_out is ready to capture.
        pkt_bytes.delete();
        while (1) begin
          if (vif.mon_cb.data_valid) begin
            pkt_bytes.push_back(vif.mon_cb.data_in);
          end

          // Check for clear overlap
          if (vif.mon_cb.clear && !vif.mon_cb.data_valid) begin
            txn.assert_clear_overlap = 1;
          end

          // data_valid dropped and we have at least one byte
          if (!vif.mon_cb.data_valid && pkt_bytes.size() > 0) begin
            // Lookahead: is this a gap or end-of-packet?
            @(vif.mon_cb);

            if (vif.mon_cb.data_valid) begin
              // Gap -- data_valid recovered; the top of the loop
              // will collect this byte on the next iteration.
              txn.insert_gap = 1;
              continue;
            end

            // End of packet. crc_out is valid on this cycle
            // (1 cycle after last data_valid deasserted).
            txn.crc_out   = vif.mon_cb.crc_out;
            txn.crc_valid = vif.mon_cb.crc_valid;

            // NOTE: Do NOT check clear here -- a clear on this cycle
            // belongs to the NEXT transaction's init, not this one.
            // True clear-overlap is already caught in the main loop
            // above (clear && !data_valid while collecting bytes).

            // Catch next transaction's start pulse if already visible
            if (vif.mon_cb.start) begin
              saw_start      = 1;
              saved_crc_init = vif.mon_cb.crc_init;
            end

            break;
          end
          @(vif.mon_cb);
        end

        // Pack collected bytes
        txn.payload_len = pkt_bytes.size();
        txn.payload = new[pkt_bytes.size()];
        foreach (pkt_bytes[i]) txn.payload[i] = pkt_bytes[i];

        `uvm_info("MON", $sformatf("Observed: %s", txn.convert2string()), UVM_HIGH)
        ap.write(txn);
      end
    endtask

  endclass


  // ==========================================================
  //  SCOREBOARD -- compares DUT output against reference model
  //
  //  PORTABILITY: works identically at unit and system level.
  // ==========================================================
  class crc24_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(crc24_scoreboard)

    uvm_analysis_imp #(crc24_seq_item, crc24_scoreboard) analysis_export;

    int unsigned pass_count;
    int unsigned fail_count;
    int unsigned total_count;

    // Per-category counters for detailed reporting
    int unsigned normal_pass, normal_fail;
    int unsigned gap_pass, gap_fail;
    int unsigned clear_ovlp_pass, clear_ovlp_fail;
    int unsigned start_count, clear_count;
    int unsigned min_len, max_len;
    int unsigned len_hist[int unsigned]; // length -> count
    int unsigned init_hist[logic [23:0]]; // init -> count

    function new(string name = "crc24_scoreboard", uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      analysis_export = new("analysis_export", this);
      pass_count  = 0;
      fail_count  = 0;
      total_count = 0;
      normal_pass = 0; normal_fail = 0;
      gap_pass = 0; gap_fail = 0;
      clear_ovlp_pass = 0; clear_ovlp_fail = 0;
      start_count = 0; clear_count = 0;
      min_len = 999; max_len = 0;
    endfunction

    function void write(crc24_seq_item txn);
      logic [23:0] expected;
      logic [23:0] init;

      total_count++;

      // Track statistics
      if (txn.use_start) start_count++; else clear_count++;
      if (txn.payload_len < min_len) min_len = txn.payload_len;
      if (txn.payload_len > max_len) max_len = txn.payload_len;
      if (len_hist.exists(txn.payload_len))
        len_hist[txn.payload_len]++;
      else
        len_hist[txn.payload_len] = 1;

      init = txn.use_start ? txn.crc_init : 24'h000000;
      if (init_hist.exists(init))
        init_hist[init]++;
      else
        init_hist[init] = 1;

      expected = crc24_ref_model::compute(txn.payload, txn.payload_len, init);

      // Handle clear-overlap: DUT zeros crc_out when clear fires
      if (txn.assert_clear_overlap) begin
        if (txn.crc_out === 24'h000000) begin
          pass_count++; clear_ovlp_pass++;
          `uvm_info("SCB", $sformatf("PASS [clear-overlap] len=%0d crc_out=0x000000",
                                      txn.payload_len), UVM_MEDIUM)
        end else begin
          fail_count++; clear_ovlp_fail++;
          `uvm_error("SCB", $sformatf("FAIL [clear-overlap] len=%0d got=0x%06h expected=0x000000",
                                       txn.payload_len, txn.crc_out))
        end
        return;
      end

      // Normal comparison
      if (txn.crc_out === expected) begin
        pass_count++;
        if (txn.insert_gap) gap_pass++; else normal_pass++;
        `uvm_info("SCB", $sformatf("PASS len=%0d init=0x%06h crc=0x%06h",
                                    txn.payload_len, init, txn.crc_out), UVM_MEDIUM)
      end else begin
        string diagnosis;
        fail_count++;
        if (txn.insert_gap) gap_fail++; else normal_fail++;

        // Diagnose likely cause of failure
        if (txn.crc_out === 24'h000000 && expected !== 24'h000000)
          diagnosis = " [likely reset cleared crc_out before monitor captured it]";
        else if (init == 24'h000000 && txn.use_start)
          diagnosis = " [monitor may have missed start pulse -- init reported as 0]";
        else
          diagnosis = "";

        `uvm_error("SCB", $sformatf("FAIL len=%0d init=0x%06h got=0x%06h expected=0x%06h%s",
                                     txn.payload_len, init, txn.crc_out, expected, diagnosis))
      end
    endfunction

    function void report_phase(uvm_phase phase);
      string result_str;
      int unsigned unique_lens, unique_inits;
      logic [23:0] init_key;

      super.report_phase(phase);

      unique_lens = len_hist.size();
      unique_inits = init_hist.size();

      result_str = (fail_count == 0) ? "ALL PASS" : $sformatf("%0d FAILED", fail_count);

      `uvm_info("SCB", $sformatf("\n\
==================== SCOREBOARD REPORT ====================\n\
  Result          : %s\n\
  Total txns      : %0d\n\
  Pass            : %0d\n\
  Fail            : %0d\n\
\n\
  --- By Category ---\n\
  Normal          : %0d pass / %0d fail\n\
  Gap (dv pause)  : %0d pass / %0d fail\n\
  Clear overlap   : %0d pass / %0d fail\n\
\n\
  --- Stimulus Profile ---\n\
  Init via start  : %0d txns\n\
  Init via clear  : %0d txns\n\
  Payload lengths : %0d unique values, range [%0d : %0d]\n\
  Init seeds      : %0d unique values\n\
===========================================================",
        result_str, total_count, pass_count, fail_count,
        normal_pass, normal_fail,
        gap_pass, gap_fail,
        clear_ovlp_pass, clear_ovlp_fail,
        start_count, clear_count,
        unique_lens, min_len, max_len,
        unique_inits), UVM_LOW)

      if (fail_count > 0)
        `uvm_error("SCB", $sformatf("%0d transactions FAILED", fail_count))
    endfunction

  endclass


  // ==========================================================
  //  COVERAGE COLLECTOR -- transaction-level functional coverage
  //
  //  Separated from scoreboard per UVM best practice.
  //  PORTABILITY: samples from transaction fields, not raw
  //  signals -- works at any integration level.
  // ==========================================================
  class crc24_coverage extends uvm_subscriber #(crc24_seq_item);
    `uvm_component_utils(crc24_coverage)

    // Local fields sampled by covergroup
    int unsigned  sampled_len;
    logic [7:0]   sampled_data_byte;
    logic [23:0]  sampled_crc_out;
    logic [23:0]  sampled_crc_init;
    bit           sampled_use_start;
    bit           sampled_clear_overlap;
    bit           sampled_insert_gap;

    covergroup cg_crc24 with function sample();
      option.per_instance = 1;
      option.name = "cg_crc24";

      // CP1 -- Packet length
      cp_pkt_len : coverpoint sampled_len {
        bins single_byte = {1};
        bins short_pkt   = {[2:3]};
        bins mid_pkt     = {[4:6]};
        bins long_pkt    = {[7:8]};
        bins ble_adv     = {[9:37]};
      }

      // CP2 -- First payload byte (representative of data range)
      cp_data_in : coverpoint sampled_data_byte {
        bins all_zeros = {8'h00};
        bins all_ones  = {8'hFF};
        bins low_vals  = {[8'h01:8'h7F]};
        bins high_vals = {[8'h80:8'hFE]};
      }

      // CP3 -- CRC output value
      cp_crc_out : coverpoint sampled_crc_out {
        bins crc_zero   = {24'h000000};
        bins crc_ones   = {24'hFFFFFF};
        bins crc_others = default;
      }

      // CP4 -- CRC init seed
      cp_init : coverpoint sampled_crc_init {
        bins ble_default = {24'h555555};
        bins all_zeros   = {24'h000000};
        bins all_ones    = {24'hFFFFFF};
        bins others      = default;
      }

      // CP5 -- Transaction type (start vs clear)
      cp_txn_type : coverpoint sampled_use_start {
        bins with_start = {1'b1};
        bins with_clear = {1'b0};
      }

      // CP6 -- Gap insertion
      cp_gap : coverpoint sampled_insert_gap {
        bins no_gap  = {1'b0};
        bins has_gap = {1'b1};
      }

      // CP7 -- Clear overlap corner case
      cp_clear_overlap : coverpoint sampled_clear_overlap {
        bins normal  = {1'b0};
        bins overlap = {1'b1};
      }

      // CROSS 1: data byte x packet length (4x5 = 20 bins)
      cx_data_pktlen : cross cp_data_in, cp_pkt_len;

      // CROSS 2: packet length x init seed (5x4 = 20 bins)
      cx_pkt_len_init : cross cp_pkt_len, cp_init;

      // CROSS 3: packet length x transaction type (5x2 = 10 bins)
      cx_pkt_len_txntype : cross cp_pkt_len, cp_txn_type;

      // CROSS 4: packet length x gap insertion (5x2 = 10 bins)
      cx_pkt_len_gap : cross cp_pkt_len, cp_gap;

    endgroup

    function new(string name = "crc24_coverage", uvm_component parent);
      super.new(name, parent);
      cg_crc24 = new();
    endfunction

    function void write(crc24_seq_item t);
      sampled_len           = t.payload_len;
      sampled_data_byte     = (t.payload_len > 0) ? t.payload[0] : 8'h00;
      sampled_crc_out       = t.crc_out;
      sampled_crc_init      = t.use_start ? t.crc_init : 24'h000000;
      sampled_use_start     = t.use_start;
      sampled_clear_overlap = t.assert_clear_overlap;
      sampled_insert_gap    = t.insert_gap;

      cg_crc24.sample();

      `uvm_info("COV", $sformatf("Sampled: len=%0d data[0]=0x%02h init=0x%06h crc=0x%06h",
                sampled_len, sampled_data_byte, sampled_crc_init, sampled_crc_out), UVM_HIGH)
    endfunction

    function void report_phase(uvm_phase phase);
      real overall;
      real cp_pkt_len_cov, cp_data_in_cov, cp_crc_out_cov, cp_init_cov;
      real cp_txn_type_cov, cp_gap_cov, cp_clear_overlap_cov;
      real cx_data_pktlen_cov, cx_pkt_len_init_cov;
      real cx_pkt_len_txntype_cov, cx_pkt_len_gap_cov;
      int  cp_count, cp_hit;
      int  cx_count, cx_hit;
      string grade;

      super.report_phase(phase);

      overall              = cg_crc24.get_coverage();
      cp_pkt_len_cov       = cg_crc24.cp_pkt_len.get_coverage();
      cp_data_in_cov       = cg_crc24.cp_data_in.get_coverage();
      cp_crc_out_cov       = cg_crc24.cp_crc_out.get_coverage();
      cp_init_cov          = cg_crc24.cp_init.get_coverage();
      cp_txn_type_cov      = cg_crc24.cp_txn_type.get_coverage();
      cp_gap_cov           = cg_crc24.cp_gap.get_coverage();
      cp_clear_overlap_cov = cg_crc24.cp_clear_overlap.get_coverage();
      cx_data_pktlen_cov   = cg_crc24.cx_data_pktlen.get_coverage();
      cx_pkt_len_init_cov  = cg_crc24.cx_pkt_len_init.get_coverage();
      cx_pkt_len_txntype_cov = cg_crc24.cx_pkt_len_txntype.get_coverage();
      cx_pkt_len_gap_cov   = cg_crc24.cx_pkt_len_gap.get_coverage();

      // Count how many coverpoints/crosses hit 100%
      cp_count = 7; cp_hit = 0;
      if (cp_pkt_len_cov       >= 100.0) cp_hit++;
      if (cp_data_in_cov       >= 100.0) cp_hit++;
      if (cp_crc_out_cov       >= 100.0) cp_hit++;
      if (cp_init_cov          >= 100.0) cp_hit++;
      if (cp_txn_type_cov      >= 100.0) cp_hit++;
      if (cp_gap_cov           >= 100.0) cp_hit++;
      if (cp_clear_overlap_cov >= 100.0) cp_hit++;

      cx_count = 4; cx_hit = 0;
      if (cx_data_pktlen_cov     >= 100.0) cx_hit++;
      if (cx_pkt_len_init_cov    >= 100.0) cx_hit++;
      if (cx_pkt_len_txntype_cov >= 100.0) cx_hit++;
      if (cx_pkt_len_gap_cov     >= 100.0) cx_hit++;

      if (overall >= 100.0)     grade = "COMPLETE";
      else if (overall >= 90.0) grade = "GOOD";
      else if (overall >= 75.0) grade = "ADEQUATE";
      else                      grade = "INCOMPLETE";

      `uvm_info("COV", $sformatf("\n\
===================== COVERAGE REPORT =====================\n\
  Overall           : %6.2f%%  [%s]\n\
  Coverpoints at 100%%: %0d / %0d\n\
  Crosses at 100%%    : %0d / %0d\n\
\n\
  --- Coverpoints (7) ---                      Bins   Cov\n\
  cp_pkt_len          Packet length          :  5    %5.1f%%\n\
  cp_data_in          First data byte        :  4    %5.1f%%\n\
  cp_crc_out          CRC output value       :  3    %5.1f%%\n\
  cp_init             Init seed              :  4    %5.1f%%\n\
  cp_txn_type         Start vs clear         :  2    %5.1f%%\n\
  cp_gap              Gap insertion          :  2    %5.1f%%\n\
  cp_clear_overlap    Clear overlap          :  2    %5.1f%%\n\
\n\
  --- Cross Coverage (4) ---                   Bins   Cov\n\
  cx_data_pktlen      data x length          : 20    %5.1f%%\n\
  cx_pkt_len_init     length x init          : 20    %5.1f%%\n\
  cx_pkt_len_txntype  length x start/clear   : 10    %5.1f%%\n\
  cx_pkt_len_gap      length x gap           : 10    %5.1f%%\n\
\n\
  --- Gaps (coverpoints below 100%%) ---",
        overall, grade,
        cp_hit, cp_count,
        cx_hit, cx_count,
        cp_pkt_len_cov, cp_data_in_cov, cp_crc_out_cov, cp_init_cov,
        cp_txn_type_cov, cp_gap_cov, cp_clear_overlap_cov,
        cx_data_pktlen_cov, cx_pkt_len_init_cov,
        cx_pkt_len_txntype_cov, cx_pkt_len_gap_cov), UVM_LOW)

      // Report which specific items are below 100%
      if (cp_pkt_len_cov < 100.0)
        `uvm_info("COV", $sformatf("  cp_pkt_len: missing bins in {1, 2-3, 4-6, 7-8, 9-37}"), UVM_LOW)
      if (cp_data_in_cov < 100.0)
        `uvm_info("COV", $sformatf("  cp_data_in: missing bins in {0x00, 0xFF, low, high}"), UVM_LOW)
      if (cp_crc_out_cov < 100.0)
        `uvm_info("COV", $sformatf("  cp_crc_out: missing bins in {0x000000, 0xFFFFFF, other} (0xFFFFFF is rare)"), UVM_LOW)
      if (cp_init_cov < 100.0)
        `uvm_info("COV", $sformatf("  cp_init: missing bins in {0x555555, 0x000000, 0xFFFFFF, other}"), UVM_LOW)
      if (cp_txn_type_cov < 100.0)
        `uvm_info("COV", $sformatf("  cp_txn_type: missing with_clear bin (no use_start=0 transactions)"), UVM_LOW)
      if (cp_gap_cov < 100.0)
        `uvm_info("COV", $sformatf("  cp_gap: missing bins in {no_gap, has_gap}"), UVM_LOW)
      if (cp_clear_overlap_cov < 100.0)
        `uvm_info("COV", $sformatf("  cp_clear_overlap: missing bins in {normal, overlap}"), UVM_LOW)
      if (cx_data_pktlen_cov < 100.0)
        `uvm_info("COV", $sformatf("  cx_data_pktlen: %0d/20 cross bins hit",
                  $rtoi(cx_data_pktlen_cov * 20.0 / 100.0)), UVM_LOW)
      if (cx_pkt_len_init_cov < 100.0)
        `uvm_info("COV", $sformatf("  cx_pkt_len_init: %0d/20 cross bins hit",
                  $rtoi(cx_pkt_len_init_cov * 20.0 / 100.0)), UVM_LOW)
      if (cx_pkt_len_txntype_cov < 100.0)
        `uvm_info("COV", $sformatf("  cx_pkt_len_txntype: %0d/10 cross bins hit (need with_clear txns)",
                  $rtoi(cx_pkt_len_txntype_cov * 10.0 / 100.0)), UVM_LOW)
      if (cx_pkt_len_gap_cov < 100.0)
        `uvm_info("COV", $sformatf("  cx_pkt_len_gap: %0d/10 cross bins hit",
                  $rtoi(cx_pkt_len_gap_cov * 10.0 / 100.0)), UVM_LOW)

      if (cp_hit == cp_count && cx_hit == cx_count)
        `uvm_info("COV", "  (none -- all bins covered!)", UVM_LOW)

      `uvm_info("COV", "===========================================================", UVM_LOW)
    endfunction

  endclass


  // ==========================================================
  //  AGENT -- bundles driver + monitor + sequencer
  //
  //  PORTABILITY KEY:
  //    Unit level  -> UVM_ACTIVE  (driver + sequencer + monitor)
  //    System level -> UVM_PASSIVE (monitor only)
  // ==========================================================
  class crc24_agent extends uvm_agent;
    `uvm_component_utils(crc24_agent)

    crc24_driver                    driver;
    crc24_monitor                   monitor;
    uvm_sequencer #(crc24_seq_item) sequencer;

    // Analysis port forwarded from monitor
    uvm_analysis_port #(crc24_seq_item) ap;

    function new(string name = "crc24_agent", uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);

      // Monitor always instantiated (active or passive)
      monitor = crc24_monitor::type_id::create("monitor", this);

      // Driver + sequencer only in active mode
      if (get_is_active() == UVM_ACTIVE) begin
        driver    = crc24_driver::type_id::create("driver", this);
        sequencer = uvm_sequencer#(crc24_seq_item)::type_id::create("sequencer", this);
      end
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);

      // Forward monitor's analysis port
      ap = monitor.ap;

      // Connect driver <-> sequencer in active mode
      if (get_is_active() == UVM_ACTIVE) begin
        driver.seq_item_port.connect(sequencer.seq_item_export);
      end
    endfunction

  endclass


  // ==========================================================
  //  ENVIRONMENT -- connects agent, scoreboard, coverage
  //
  //  PORTABILITY: instantiate as sub-env at system level.
  //  Config knobs via uvm_config_db:
  //    - "is_active"      -> UVM_ACTIVE / UVM_PASSIVE
  //    - "has_scoreboard" -> enable/disable
  //    - "has_coverage"   -> enable/disable
  // ==========================================================
  class crc24_env extends uvm_env;
    `uvm_component_utils(crc24_env)

    crc24_agent       agent;
    crc24_scoreboard  scoreboard;
    crc24_coverage    coverage;

    bit has_scoreboard = 1;
    bit has_coverage   = 1;

    function new(string name = "crc24_env", uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);

      uvm_config_db#(bit)::get(this, "", "has_scoreboard", has_scoreboard);
      uvm_config_db#(bit)::get(this, "", "has_coverage", has_coverage);

      agent = crc24_agent::type_id::create("agent", this);

      if (has_scoreboard)
        scoreboard = crc24_scoreboard::type_id::create("scoreboard", this);

      if (has_coverage)
        coverage = crc24_coverage::type_id::create("coverage", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);

      if (has_scoreboard)
        agent.ap.connect(scoreboard.analysis_export);

      if (has_coverage)
        agent.ap.connect(coverage.analysis_export);
    endfunction

  endclass


  // ==========================================================
  //  SEQUENCES -- reusable, composable stimulus
  // ==========================================================

  // --- Base: single randomized transaction ---
  class crc24_base_seq extends uvm_sequence #(crc24_seq_item);
    `uvm_object_utils(crc24_base_seq)

    function new(string name = "crc24_base_seq");
      super.new(name);
    endfunction

    task body();
      crc24_seq_item txn;
      txn = crc24_seq_item::type_id::create("txn");
      start_item(txn);
      if (!txn.randomize())
        `uvm_error("SEQ", "Randomization failed")
      finish_item(txn);
    endtask
  endclass

  // --- Directed: all zeros payload ---
  class crc24_zeros_seq extends uvm_sequence #(crc24_seq_item);
    `uvm_object_utils(crc24_zeros_seq)

    int unsigned pkt_len = 4;

    function new(string name = "crc24_zeros_seq");
      super.new(name);
    endfunction

    task body();
      crc24_seq_item txn;
      txn = crc24_seq_item::type_id::create("txn");
      start_item(txn);
      if (!txn.randomize() with {
        payload_len == pkt_len;
        foreach (payload[i]) payload[i] == 8'h00;
        use_start == 1;
        crc_init == 24'h555555;
        insert_gap == 0;
        assert_clear_overlap == 0;
      })
        `uvm_error("SEQ", "Randomization failed")
      finish_item(txn);
    endtask
  endclass

  // --- Directed: all ones payload ---
  class crc24_ones_seq extends uvm_sequence #(crc24_seq_item);
    `uvm_object_utils(crc24_ones_seq)

    int unsigned pkt_len = 4;

    function new(string name = "crc24_ones_seq");
      super.new(name);
    endfunction

    task body();
      crc24_seq_item txn;
      txn = crc24_seq_item::type_id::create("txn");
      start_item(txn);
      if (!txn.randomize() with {
        payload_len == pkt_len;
        foreach (payload[i]) payload[i] == 8'hFF;
        use_start == 1;
        crc_init == 24'h555555;
        insert_gap == 0;
        assert_clear_overlap == 0;
      })
        `uvm_error("SEQ", "Randomization failed")
      finish_item(txn);
    endtask
  endclass

  // --- BLE init: exercises BLE default init seed ---
  class crc24_ble_init_seq extends uvm_sequence #(crc24_seq_item);
    `uvm_object_utils(crc24_ble_init_seq)

    function new(string name = "crc24_ble_init_seq");
      super.new(name);
    endfunction

    task body();
      crc24_seq_item txn;
      txn = crc24_seq_item::type_id::create("txn");
      start_item(txn);
      if (!txn.randomize() with {
        use_start == 1;
        crc_init == 24'h555555;
        insert_gap == 0;
        assert_clear_overlap == 0;
      })
        `uvm_error("SEQ", "Randomization failed")
      finish_item(txn);
    endtask
  endclass

  // --- Gap: insert data_valid gap mid-packet ---
  class crc24_gap_seq extends uvm_sequence #(crc24_seq_item);
    `uvm_object_utils(crc24_gap_seq)

    function new(string name = "crc24_gap_seq");
      super.new(name);
    endfunction

    task body();
      crc24_seq_item txn;
      txn = crc24_seq_item::type_id::create("txn");
      start_item(txn);
      if (!txn.randomize() with {
        payload_len >= 4;
        use_start == 1;
        insert_gap == 1;
        assert_clear_overlap == 0;
      })
        `uvm_error("SEQ", "Randomization failed")
      finish_item(txn);
    endtask
  endclass

  // --- Clear overlap: corner case ---
  class crc24_clear_overlap_seq extends uvm_sequence #(crc24_seq_item);
    `uvm_object_utils(crc24_clear_overlap_seq)

    function new(string name = "crc24_clear_overlap_seq");
      super.new(name);
    endfunction

    task body();
      crc24_seq_item txn;
      txn = crc24_seq_item::type_id::create("txn");
      start_item(txn);
      if (!txn.randomize() with {
        use_start == 1;
        insert_gap == 0;
        assert_clear_overlap == 1;
      })
        `uvm_error("SEQ", "Randomization failed")
      finish_item(txn);
    endtask
  endclass

  // --- Directed cross-coverage: hits all cx_data_pktlen bins ---
  class crc24_cross_coverage_seq extends uvm_sequence #(crc24_seq_item);
    `uvm_object_utils(crc24_cross_coverage_seq)

    function new(string name = "crc24_cross_coverage_seq");
      super.new(name);
    endfunction

    task body();
      crc24_seq_item txn;
      logic [7:0] data_vals[] = '{8'h00, 8'hFF, 8'h42, 8'hA5};
      int pkt_lens[] = '{1, 2, 5, 8, 15};

      foreach (data_vals[d]) begin
        foreach (pkt_lens[p]) begin
          txn = crc24_seq_item::type_id::create("txn");
          start_item(txn);
          if (!txn.randomize() with {
            payload_len == pkt_lens[p];
            foreach (payload[i]) payload[i] == data_vals[d];
            use_start == 1;
            crc_init == 24'h555555;
            insert_gap == 0;
            assert_clear_overlap == 0;
          })
            `uvm_error("SEQ", "Randomization failed")
          finish_item(txn);
        end
      end
    endtask
  endclass

  // --- Init cross-coverage: hits cx_pkt_len_init bins ---
  class crc24_init_cross_seq extends uvm_sequence #(crc24_seq_item);
    `uvm_object_utils(crc24_init_cross_seq)

    function new(string name = "crc24_init_cross_seq");
      super.new(name);
    endfunction

    task body();
      crc24_seq_item txn;
      logic [23:0] inits[] = '{24'h555555, 24'h000000, 24'hFFFFFF, 24'hABCDEF};
      int pkt_lens[] = '{1, 3, 5, 7, 12};

      foreach (inits[i]) begin
        foreach (pkt_lens[p]) begin
          txn = crc24_seq_item::type_id::create("txn");
          start_item(txn);
          if (!txn.randomize() with {
            payload_len == pkt_lens[p];
            use_start == 1;
            crc_init == inits[i];
            insert_gap == 0;
            assert_clear_overlap == 0;
          })
            `uvm_error("SEQ", "Randomization failed")
          finish_item(txn);
        end
      end
    endtask
  endclass

  // --- Random regression: N randomized transactions ---
  class crc24_random_seq extends uvm_sequence #(crc24_seq_item);
    `uvm_object_utils(crc24_random_seq)

    int unsigned num_txns = 50;

    function new(string name = "crc24_random_seq");
      super.new(name);
    endfunction

    task body();
      crc24_seq_item txn;
      repeat (num_txns) begin
        txn = crc24_seq_item::type_id::create("txn");
        start_item(txn);
        if (!txn.randomize())
          `uvm_error("SEQ", "Randomization failed")
        finish_item(txn);
      end
    endtask
  endclass

  // --- Clear-based init: uses clear instead of start (hits cp_txn_type with_clear) ---
  class crc24_clear_init_seq extends uvm_sequence #(crc24_seq_item);
    `uvm_object_utils(crc24_clear_init_seq)

    function new(string name = "crc24_clear_init_seq");
      super.new(name);
    endfunction

    task body();
      crc24_seq_item txn;
      int pkt_lens[] = '{1, 3, 5, 7, 12};

      foreach (pkt_lens[p]) begin
        txn = crc24_seq_item::type_id::create("txn");
        start_item(txn);
        if (!txn.randomize() with {
          payload_len == pkt_lens[p];
          use_start == 0;
          insert_gap == 0;
          assert_clear_overlap == 0;
        })
          `uvm_error("SEQ", "Randomization failed")
        finish_item(txn);
      end
    endtask
  endclass

  // --- Gap cross-coverage: hits cx_pkt_len_gap for short packets ---
  class crc24_gap_cross_seq extends uvm_sequence #(crc24_seq_item);
    `uvm_object_utils(crc24_gap_cross_seq)

    function new(string name = "crc24_gap_cross_seq");
      super.new(name);
    endfunction

    task body();
      crc24_seq_item txn;
      // Need gaps at each length bin: 2-3 (short), 4-6 (mid), 7-8 (long), 9+ (ble_adv)
      // single_byte (1) can't have a gap (gap_at = 0, only 1 byte)
      int pkt_lens[] = '{2, 5, 8, 15};

      foreach (pkt_lens[p]) begin
        txn = crc24_seq_item::type_id::create("txn");
        start_item(txn);
        if (!txn.randomize() with {
          payload_len == pkt_lens[p];
          use_start == 1;
          crc_init == 24'h555555;
          insert_gap == 1;
          assert_clear_overlap == 0;
        })
          `uvm_error("SEQ", "Randomization failed")
        finish_item(txn);
      end
    endtask
  endclass


  // ==========================================================
  //  TESTS
  // ==========================================================

  // --- Base test: reset + env setup ---
  class crc24_base_test extends uvm_test;
    `uvm_component_utils(crc24_base_test)

    crc24_env env;

    function new(string name = "crc24_base_test", uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = crc24_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
      phase.raise_objection(this, "base_test");

      `uvm_info("TEST", "Asserting reset", UVM_LOW)
      env.agent.driver.reset_dut(4);
      `uvm_info("TEST", "Reset complete", UVM_LOW)

      phase.drop_objection(this, "base_test");
    endtask

  endclass

  // --- Smoke test: single known packets ---
  class crc24_smoke_test extends crc24_base_test;
    `uvm_component_utils(crc24_smoke_test)

    function new(string name = "crc24_smoke_test", uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      crc24_zeros_seq zeros_seq;
      crc24_ones_seq  ones_seq;

      phase.raise_objection(this, "smoke_test");

      env.agent.driver.reset_dut(4);

      zeros_seq = crc24_zeros_seq::type_id::create("zeros_seq");
      zeros_seq.pkt_len = 1;
      zeros_seq.start(env.agent.sequencer);

      ones_seq = crc24_ones_seq::type_id::create("ones_seq");
      ones_seq.pkt_len = 1;
      ones_seq.start(env.agent.sequencer);

      phase.drop_objection(this, "smoke_test");
    endtask
  endclass

  // --- Directed coverage test: hits all cross-coverage bins ---
  class crc24_directed_test extends crc24_base_test;
    `uvm_component_utils(crc24_directed_test)

    function new(string name = "crc24_directed_test", uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      crc24_cross_coverage_seq cross_seq;
      crc24_init_cross_seq     init_seq;
      crc24_gap_seq            gap_seq;
      crc24_clear_overlap_seq  clr_seq;

      phase.raise_objection(this, "directed_test");

      env.agent.driver.reset_dut(4);

      `uvm_info("TEST", "Phase: cross coverage", UVM_LOW)
      cross_seq = crc24_cross_coverage_seq::type_id::create("cross_seq");
      cross_seq.start(env.agent.sequencer);

      `uvm_info("TEST", "Phase: init cross coverage", UVM_LOW)
      init_seq = crc24_init_cross_seq::type_id::create("init_seq");
      init_seq.start(env.agent.sequencer);

      `uvm_info("TEST", "Phase: gap tests", UVM_LOW)
      repeat (5) begin
        gap_seq = crc24_gap_seq::type_id::create("gap_seq");
        gap_seq.start(env.agent.sequencer);
      end

      `uvm_info("TEST", "Phase: clear overlap", UVM_LOW)
      repeat (3) begin
        clr_seq = crc24_clear_overlap_seq::type_id::create("clr_seq");
        clr_seq.start(env.agent.sequencer);
      end

      phase.drop_objection(this, "directed_test");
    endtask
  endclass

  // --- Full regression: directed + random ---
  class crc24_full_test extends crc24_base_test;
    `uvm_component_utils(crc24_full_test)

    function new(string name = "crc24_full_test", uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      crc24_cross_coverage_seq cross_seq;
      crc24_init_cross_seq     init_seq;
      crc24_gap_seq            gap_seq;
      crc24_gap_cross_seq      gap_cross_seq;
      crc24_clear_overlap_seq  clr_seq;
      crc24_clear_init_seq     clr_init_seq;
      crc24_ble_init_seq       ble_seq;
      crc24_random_seq         rand_seq;

      phase.raise_objection(this, "full_test");

      // Phase 1: Reset
      `uvm_info("TEST", "[Phase 1] Reset", UVM_LOW)
      env.agent.driver.reset_dut(4);

      // Phase 2: Directed cross-coverage (data x length)
      `uvm_info("TEST", "[Phase 2] Directed cross-coverage", UVM_LOW)
      cross_seq = crc24_cross_coverage_seq::type_id::create("cross_seq");
      cross_seq.start(env.agent.sequencer);

      // Phase 3: Init seed cross-coverage (length x init)
      `uvm_info("TEST", "[Phase 3] Init seed coverage", UVM_LOW)
      init_seq = crc24_init_cross_seq::type_id::create("init_seq");
      init_seq.start(env.agent.sequencer);

      // Phase 3.5: BLE-specific init
      `uvm_info("TEST", "[Phase 3.5] BLE init sequences", UVM_LOW)
      repeat (5) begin
        ble_seq = crc24_ble_init_seq::type_id::create("ble_seq");
        ble_seq.start(env.agent.sequencer);
      end

      // Phase 4: Corner cases (gaps, clear overlap)
      `uvm_info("TEST", "[Phase 4] Corner cases", UVM_LOW)
      repeat (5) begin
        gap_seq = crc24_gap_seq::type_id::create("gap_seq");
        gap_seq.start(env.agent.sequencer);
      end
      repeat (3) begin
        clr_seq = crc24_clear_overlap_seq::type_id::create("clr_seq");
        clr_seq.start(env.agent.sequencer);
      end

      // Phase 5: Mid-transaction reset
      // NOTE: The pre-reset packet's crc_out may be zeroed by the DUT
      // before the monitor captures it. This is a known monitor timing
      // limitation, not a DUT bug. The recovery packet verifies the
      // DUT resumes correctly after reset.
      `uvm_info("TEST", "[Phase 5] Mid-transaction reset", UVM_LOW)
      begin
        crc24_base_seq single_seq;
        single_seq = crc24_base_seq::type_id::create("single_seq");
        single_seq.start(env.agent.sequencer);
        // Wait 2 cycles for monitor to capture crc_out before reset
        repeat (2) @(env.agent.driver.vif.drv_cb);
        env.agent.driver.reset_dut(2);
        single_seq = crc24_base_seq::type_id::create("recovery_seq");
        single_seq.start(env.agent.sequencer);
      end

      // Phase 6: Clear-based init coverage (cp_txn_type, cx_pkt_len_txntype)
      `uvm_info("TEST", "[Phase 6] Clear-based init coverage", UVM_LOW)
      clr_init_seq = crc24_clear_init_seq::type_id::create("clr_init_seq");
      clr_init_seq.start(env.agent.sequencer);

      // Phase 7: Gap cross-coverage (cx_pkt_len_gap for short packets)
      `uvm_info("TEST", "[Phase 7] Gap cross-coverage", UVM_LOW)
      gap_cross_seq = crc24_gap_cross_seq::type_id::create("gap_cross_seq");
      gap_cross_seq.start(env.agent.sequencer);

      // Phase 8: Random regression
      `uvm_info("TEST", "[Phase 8] Random regression (50 packets)", UVM_LOW)
      rand_seq = crc24_random_seq::type_id::create("rand_seq");
      rand_seq.num_txns = 50;
      rand_seq.start(env.agent.sequencer);

      `uvm_info("TEST_DONE", "All test phases complete", UVM_LOW)
      phase.drop_objection(this, "full_test");
    endtask
  endclass

endpackage


// ============================================================
//  TOP-LEVEL MODULE -- clock, interface, DUT, UVM launch
//
//  This is the ONLY thing that changes between unit and
//  system level.  Everything else is reused via crc24_pkg.
// ============================================================
module tb_top;

  import uvm_pkg::*;
  import crc24_pkg::*;
  `include "uvm_macros.svh"

  // Clock generation
  logic clk;
  initial begin
    clk = 0;
    forever #5 clk = ~clk; // 100 MHz
  end

  // Interface
  crc24_if vif(.clk(clk));

  // DUT
  crc24 dut (
    .clk       (clk),
    .rst_n     (vif.rst_n),
    .start     (vif.start),
    .clear     (vif.clear),
    .crc_init  (vif.crc_init),
    .data_in   (vif.data_in),
    .data_valid(vif.data_valid),
    .crc_out   (vif.crc_out),
    .crc_valid (vif.crc_valid)
  );

  // Pass virtual interface to UVM and launch test
  initial begin
    uvm_config_db#(virtual crc24_if)::set(null, "uvm_test_top.*", "vif", vif);
    run_test();
  end

  // Waveform dump (optional)
  initial begin
    $dumpfile("crc24.vcd");
    $dumpvars(0, tb_top);
  end

endmodule
