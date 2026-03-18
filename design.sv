// ============================================================
//  design.sv -- CRC-24/BLE DUT + Interface
//
//  BLE polynomial: x^24+x^10+x^9+x^6+x^4+x^3+x+1 = 0x00065B
//  Reflected for LSB-first processing:              0xDA6000
//  BLE default init (advertising channel):          0x555555
// ============================================================



// ------------ CRC-24/BLE RTL module -------------------------
module crc24 (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,       // load crc_init and begin new transaction
  input  logic        clear,       // synchronous reset to 0x000000
  input  logic [23:0] crc_init,    // CRC seed loaded on start
  input  logic [7:0]  data_in,
  input  logic        data_valid,
  output logic [23:0] crc_out,
  output logic        crc_valid
);
  // Reflected BLE polynomial for LSB-first shift-right processing
  localparam [23:0] POLY = 24'hDA6000;

  logic [23:0] crc_reg, crc_next;
  logic        valid_delay;
  logic [23:0] crc_out_reg;

  // Process one byte LSB first (BLE bit ordering)
  function automatic logic [23:0] compute_crc(
    input logic [23:0] crc_in,
    input logic [7:0]  data
  );
    logic [23:0] crc;
    logic        feedback;
    crc = crc_in;
    for (int i = 0; i < 8; i++) begin   // LSB first
      feedback = data[i] ^ crc[0];
      crc >>= 1;
      if (feedback) crc ^= POLY;
    end
    return crc;
  endfunction

  assign crc_next = data_valid ? compute_crc(crc_reg, data_in) : crc_reg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)      begin crc_reg <= 24'h000000; valid_delay <= 0; crc_out_reg <= 24'h000000; end
    else if (start)  begin crc_reg <= crc_init;   valid_delay <= 0; crc_out_reg <= 24'h000000; end
    else if (clear)  begin crc_reg <= 24'h000000; crc_out_reg <= 24'h000000; end
    else             begin crc_reg <= crc_next; valid_delay <= data_valid; crc_out_reg <= crc_reg; end
  end

  assign crc_out   = crc_out_reg;
  assign crc_valid = valid_delay;

  // ---- Assertions --------------------------------------------------------
  // SVA1: crc_valid must assert exactly 1 cycle after data_valid
  property p_crc_valid_delay;
    @(posedge clk) disable iff (!rst_n || start)
    data_valid |=> crc_valid;
  endproperty
  assert property (p_crc_valid_delay)
    else $error("ASSERT FAIL: crc_valid not asserted 1 cycle after data_valid");

  // SVA2: crc_out must never carry X/Z while crc_valid is asserted
  property p_no_x_crc;
    @(posedge clk) disable iff (!rst_n)
    crc_valid |-> !$isunknown(crc_out);
  endproperty
  assert property (p_no_x_crc)
    else $error("ASSERT FAIL: X/Z on crc_out while crc_valid=1");

  // SVA3: while in reset, crc_out must be 0x000000
  property p_rst_output_zero;
    @(posedge clk) !rst_n |-> (crc_out == 24'h000000);
  endproperty
  assert property (p_rst_output_zero)
    else $error("ASSERT FAIL: crc_out != 0x000000 during reset");

endmodule

