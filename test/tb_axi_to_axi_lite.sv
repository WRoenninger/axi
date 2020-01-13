// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Fabian Schuiki <fschuiki@iis.ee.ethz.ch>

`include "axi/assign.svh"

module tb_axi_to_axi_lite;

  parameter AW = 32;
  parameter DW = 32;
  parameter IW = 8;
  parameter UW = 8;

  localparam tCK = 1ns;
  localparam TA = tCK * 1/4;
  localparam TT = tCK * 3/4;

  localparam     MAX_READ_TXNS  = 32'd20;
  localparam     MAX_WRITE_TXNS = 32'd20;
  localparam bit AXI_ATOPS      = 1'b1;

  logic clk = 0;
  logic rst = 1;
  logic done = 0;

  AXI_LITE_DV #(
    .AXI_ADDR_WIDTH(AW),
    .AXI_DATA_WIDTH(DW)
  ) axi_lite_dv(clk);

  AXI_LITE #(
    .AXI_ADDR_WIDTH(AW),
    .AXI_DATA_WIDTH(DW)
  ) axi_lite();

  `AXI_LITE_ASSIGN(axi_lite_dv, axi_lite);

  AXI_BUS_DV #(
    .AXI_ADDR_WIDTH(AW),
    .AXI_DATA_WIDTH(DW),
    .AXI_ID_WIDTH(IW),
    .AXI_USER_WIDTH(UW)
  ) axi_dv(clk);

  AXI_BUS #(
    .AXI_ADDR_WIDTH(AW),
    .AXI_DATA_WIDTH(DW),
    .AXI_ID_WIDTH(IW),
    .AXI_USER_WIDTH(UW)
  ) axi();

  `AXI_ASSIGN(axi, axi_dv);

  axi_to_axi_lite_intf #(
    .AxiIdWidth      ( IW    ),
    .AxiAddrWidth    ( AW    ),
    .AxiDataWidth    ( DW    ),
    .AxiUserWidth    ( UW    ),
    .AxiMaxWriteTxns ( 32'd10 ),
    .AxiMaxReadTxns  ( 32'd10 ),
    .FallThrough     ( 1'b1  )
  ) i_dut (
    .clk_i      ( clk      ),
    .rst_ni     ( rst      ),
    .testmode_i ( 1'b0     ),
    .in         ( axi      ),
    .out        ( axi_lite )
  );

  typedef axi_test::rand_axi_master #(
    // AXI interface parameters
    .AW ( AW ),
    .DW ( DW ),
    .IW ( IW ),
    .UW ( UW ),
    // Stimuli application and test time
    .TA ( TA ),
    .TT ( TT ),
    // Maximum number of read and write transactions in flight
    .MAX_READ_TXNS  ( MAX_READ_TXNS  ),
    .MAX_WRITE_TXNS ( MAX_WRITE_TXNS ),
    .AXI_ATOPS      ( AXI_ATOPS      )
  ) rand_axi_master_t;
  typedef axi_test::rand_axi_lite_slave #(.AW(AW), .DW(DW), .TA(TA), .TT(TT)) rand_axi_lite_slv_t;

  rand_axi_lite_slv_t axi_lite_drv = new(axi_lite_dv);
  rand_axi_master_t   axi_drv      = new(axi_dv);

  initial begin
    #tCK;
    rst <= 0;
    #tCK;
    rst <= 1;
    #tCK;
    while (!done) begin
      clk <= 1;
      #(tCK/2);
      clk <= 0;
      #(tCK/2);
    end
  end

  initial begin
    axi_drv.add_memory_region(32'h0000_0000,
                                      32'h1000_0000,
                                      axi_pkg::NORMAL_NONCACHEABLE_NONBUFFERABLE);
    axi_drv.add_memory_region(32'h1000_0000,
                                      32'h2000_0000,
                                      axi_pkg::NORMAL_NONCACHEABLE_BUFFERABLE);
    axi_drv.add_memory_region(32'h3000_0000,
                                      32'h4000_0000,
                                      axi_pkg::WBACK_RWALLOCATE);
    axi_drv.reset();
    @(posedge rst);
    axi_drv.run(1000, 1000);

    repeat (4) @(posedge clk);
    done = 1'b1;
    repeat (4) @(posedge clk);
    $stop();
  end

  initial begin
    axi_lite_drv.reset();
    @(posedge clk);

    axi_lite_drv.run();
  end

endmodule
