// Copyright (c) 2019 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// Author: Wolfgang Roenninger <wroennin@ethz.ch>

// AXI DEMUX: This module splits an axi bus from one slv port to multiple mst ports.
// - Each AX vector takes a `slv_ax_select_i` which determines to wich mst port index
//   the corresponding axi burst gets sent. The selection signal has to be constant during
//   ax_valid.
// - There can me multiple transactions in flight to different mast ports, if
//   they have different id's. The module will stall the Ax if it goes to a different
//   mst port where other transactions with the same id are still in flight.
//   This module will reorder read responses fromm different mst ports, when the axi id's are
//   different!
// - The module handles atops. The master connected to the slv port has to handle atops accordingly.

// only used in axi_demux_wrap
`include "axi/assign.svh"
`include "axi/typedef.svh"

module axi_demux #(
  parameter int unsigned AXI_ID_WIDTH     = 1,     // ID Width
  parameter type         aw_chan_t        = logic, // AW Channel Type
  parameter type         w_chan_t         = logic, //  W Channel Type
  parameter type         b_chan_t         = logic, //  B Channel Type
  parameter type         ar_chan_t        = logic, // AR Channel Type
  parameter type         r_chan_t         = logic, //  R Channel Type
  // Number of Master ports, that can be connected to
  parameter int unsigned NO_MST_PORTS     = 3,
  // Maximum number of outstanding transactions, determined the depth of the w fifo
  parameter int unsigned MAX_TRANS        = 8,
  // lies in conjunction with max trans, but is the counter width, can be $log2 if desired
  parameter int unsigned ID_COUNTER_WIDTH = 4,
  // the lower bits of the axi id, that get used for stalling on 'same' id to a different mst port
  parameter int unsigned AXI_LOOK_BITS    = 3,
  // When enabled theoretical one cycle transaction, but long logic paths
  parameter bit          FALL_THROUGH     = 1'b0,
  // add spill register in aw path before the lookup in id counter
  parameter bit          SPILL_AW         = 1'b1,
  parameter bit          SPILL_W          = 1'b0,
  parameter bit          SPILL_B          = 1'b0,
  // add spill register in ar path before the lookup in id counter
  parameter bit          SPILL_AR         = 1'b1,
  parameter bit          SPILL_R          = 1'b0,
  // Dependent parameters, DO NOT OVERRIDE!
  parameter type         select_t       = logic [$clog2(NO_MST_PORTS)-1:0] // MST port select type
) (
  input  logic clk_i,   // Clock
  input  logic rst_ni,  // Asynchronous reset active low
  input  logic test_i,  // Testmode enable
  // slave port
  // AW channel
  input  aw_chan_t                    slv_aw_chan_i,
  input  select_t                     slv_aw_select_i, // Has to be cycle stable when slv_aw_valid_i
  input  logic                        slv_aw_valid_i,
  output logic                        slv_aw_ready_o,
  //  W channel
  input  w_chan_t                     slv_w_chan_i,
  input  logic                        slv_w_valid_i,
  output logic                        slv_w_ready_o,
  //  B channel
  output b_chan_t                     slv_b_chan_o,
  output logic                        slv_b_valid_o,
  input  logic                        slv_b_ready_i,
  // AR channel
  input  ar_chan_t                    slv_ar_chan_i,
  input  select_t                     slv_ar_select_i, // Has to be cycle stable when slv_ar_valid_i
  input  logic                        slv_ar_valid_i,
  output logic                        slv_ar_ready_o,
  //  R channel
  output r_chan_t                     slv_r_chan_o,
  output logic                        slv_r_valid_o,
  input  logic                        slv_r_ready_i,
  // master ports
  // AW channel
  output aw_chan_t [NO_MST_PORTS-1:0] mst_aw_chans_o,
  output logic     [NO_MST_PORTS-1:0] mst_aw_valids_o,
  input  logic     [NO_MST_PORTS-1:0] mst_aw_readies_i,
  //  W channel
  output w_chan_t  [NO_MST_PORTS-1:0] mst_w_chans_o,
  output logic     [NO_MST_PORTS-1:0] mst_w_valids_o,
  input  logic     [NO_MST_PORTS-1:0] mst_w_readies_i,
  //  B channel
  input  b_chan_t  [NO_MST_PORTS-1:0] mst_b_chans_i,
  input  logic     [NO_MST_PORTS-1:0] mst_b_valids_i,
  output logic     [NO_MST_PORTS-1:0] mst_b_readies_o,
  // AR channel
  output ar_chan_t [NO_MST_PORTS-1:0] mst_ar_chans_o,
  output logic     [NO_MST_PORTS-1:0] mst_ar_valids_o,
  input  logic     [NO_MST_PORTS-1:0] mst_ar_readies_i,
  //  R channel
  input  r_chan_t  [NO_MST_PORTS-1:0] mst_r_chans_i,
  input  logic     [NO_MST_PORTS-1:0] mst_r_valids_i,
  output logic     [NO_MST_PORTS-1:0] mst_r_readies_o
);
  // pass through if only one master port
  if (NO_MST_PORTS == unsigned'(1)) begin
    // aw channel
    assign mst_aw_chans_o[0]  = slv_aw_chan_i;
    assign mst_aw_valids_o[0] = slv_aw_valid_i;
    assign slv_aw_ready_o     = mst_aw_readies_i[0];
    // w channel
    assign mst_w_chans_o[0]   = slv_w_chan_i;
    assign mst_w_valids_o[0]  = slv_w_valid_i;
    assign slv_w_ready_o      = mst_w_readies_i[0];
    // b channel
    assign slv_b_chan_o       = mst_b_chans_i[0];
    assign slv_b_valid_o      = mst_b_valids_i[0];
    assign mst_b_readies_o[0] = slv_b_ready_i;
    // ar channel
    assign mst_ar_chans_o[0]  = slv_ar_chan_i;
    assign mst_ar_valids_o[0] = slv_ar_valid_i;
    assign slv_ar_ready_o     = mst_ar_readies_i[0];
    // r channel
    assign slv_r_chan_o       = mst_r_chans_i[0];
    assign slv_r_valid_o      = mst_r_valids_i[0];
    assign mst_r_readies_o[0] = slv_r_ready_i;

  // other non degenerate cases
  end else begin
    //--------------------------------------
    // Typedefs for the Fifos / Queues
    //--------------------------------------
    // localparam int unsigned AXI_ID_WIDTH = $bits();
    typedef logic [AXI_ID_WIDTH-1:0] axi_id_t;
    typedef struct packed {
      aw_chan_t aw_chan;
      select_t  aw_select;
    } aw_chan_select_t;
    typedef struct packed {
      ar_chan_t ar_chan;
      select_t  ar_select;
    } ar_chan_select_t;
    typedef struct packed {
      axi_id_t id;
      select_t select;
    } id_queue_data_t;
    id_queue_data_t id_mask;
    assign id_mask.id     = '1;
    assign id_mask.select = '0;

    //--------------------------------------
    //--------------------------------------
    // Signal Declarations
    //--------------------------------------
    //--------------------------------------

    //--------------------------------------
    // Write Transaction
    //--------------------------------------
    // comes from face in spill register or not
    aw_chan_select_t slv_aw_chan_select;
    logic            slv_aw_valid,       slv_aw_ready;

    // aw id counter
    select_t         lookup_aw_select;
    logic            aw_select_occupied, aw_id_cnt_full;
    logic            aw_push,            b_pop;
    // atop inject to the ar channel the id is from the aw channel
    logic            atop_inject;


    // Data in to the fifos is the AW'select signal
    // push signal is the same as aw_push
    // w fifo signals, holds the selection, where the next W beats should go
    logic            w_fifo_pop;
    logic            w_fifo_full,        w_fifo_empty;
    select_t         w_select;

    // decision to stall or to connect
    aw_chan_select_t aw_chan_select;
    logic            aw_valid,           aw_ready;

    // w channel from spill reg
    w_chan_t         slv_w_chan;
    logic            slv_w_valid,        slv_w_ready;
    // b channel to spill register
    b_chan_t         slv_b_chan;
    logic            slv_b_valid,        slv_b_ready;

    //--------------------------------------
    // Read Transaction
    //--------------------------------------
    // comes from face in spill register or not
    ar_chan_select_t slv_ar_chan_select;
    logic            slv_ar_valid,       slv_ar_ready;

    // aw id counter
    select_t         lookup_ar_select;
    logic            ar_select_occupied, ar_id_cnt_full;
    logic            ar_push,            r_pop;

    // decision to stall or to connect
    ar_chan_select_t ar_chan_select;
    logic            lock_ar_valid_n,    lock_ar_valid_q, load_ar_lock;
    logic            ar_valid,           ar_ready;

    // r channel to spill register
    r_chan_t         slv_r_chan;
    logic            slv_r_valid,        slv_r_ready;

    //--------------------------------------
    //--------------------------------------
    // Channel Control
    //--------------------------------------
    //--------------------------------------

    //--------------------------------------
    // AW Channel
    //--------------------------------------
    // spil register at the channel input
    if (SPILL_AW) begin : gen_spill_aw
      aw_chan_select_t slv_aw_chan_select_in;
      assign slv_aw_chan_select_in.aw_chan   = slv_aw_chan_i;
      assign slv_aw_chan_select_in.aw_select = slv_aw_select_i;
      spill_register #(
        .T       ( aw_chan_select_t      )
      ) i_aw_spill_reg (
        .clk_i   ( clk_i                 ),
        .rst_ni  ( rst_ni                ),
        .valid_i ( slv_aw_valid_i        ),
        .ready_o ( slv_aw_ready_o        ),
        .data_i  ( slv_aw_chan_select_in ),
        .valid_o ( slv_aw_valid          ),
        .ready_i ( slv_aw_ready          ),
        .data_o  ( slv_aw_chan_select    )
      );
    end else begin : gen_no_spill_aw
      assign slv_aw_chan_select.aw_chan   = slv_aw_chan_i;
      assign slv_aw_chan_select.aw_select = slv_aw_select_i;
      assign slv_aw_valid                 = slv_aw_valid_i;
      assign slv_aw_ready_o               = slv_aw_ready;
    end

    always_comb begin : proc_aw_chan
      // Axi Handshakes
      slv_aw_ready = 1'b0;
      aw_valid     = 1'b0;
      // AW id counter and W fifo
      aw_push      = 1'b0;
      // atop injection into ar counter
      atop_inject  = 1'b0;
      // can start handeling transaction, if id counter and fifo have space in them
      // also check if we could inject something
      if (!aw_id_cnt_full && !w_fifo_full && !ar_id_cnt_full) begin
        // there is a valid AW vector make the id lookup and go further, if it passes
        if (slv_aw_valid && (!aw_select_occupied ||
           (slv_aw_chan_select.aw_select == lookup_aw_select))) begin
          // connect the handshake
          aw_valid     = 1'b1;
          slv_aw_ready = aw_ready;
          // on transaction
          if (aw_ready) begin
            aw_push    = 1'b1;
            if (slv_aw_chan_select.aw_chan.atop[5]) begin
              atop_inject = 1'b1;
            end
          end
        end
      end
    end

    // assign the data from one aw spill reg to the next one
    assign aw_chan_select = slv_aw_chan_select;

    axi_demux_id_counters #(
      .AXI_ID_BITS       ( AXI_LOOK_BITS    ),
      .COUNTER_WIDTH     ( ID_COUNTER_WIDTH ),
      .mst_port_select_t ( select_t         )
    ) i_aw_id_counter (
      .clk_i                        ( clk_i                                           ),
      .rst_ni                       ( rst_ni                                          ),
      .lookup_axi_id_i              ( slv_aw_chan_select.aw_chan.id[0+:AXI_LOOK_BITS] ),
      .lookup_mst_select_o          ( lookup_aw_select                                ),
      .lookup_mst_select_occupied_o ( aw_select_occupied                              ),
      .full_o                       ( aw_id_cnt_full                                  ),
      .inject_axi_id_i              ( '0                                              ),
      .inject_i                     ( 1'b0                                            ),
      .push_axi_id_i                ( slv_aw_chan_select.aw_chan.id[0+:AXI_LOOK_BITS] ),
      .push_mst_select_i            ( slv_aw_chan_select.aw_select                    ),
      .push_i                       ( aw_push                                         ),
      .pop_axi_id_i                 ( slv_b_chan.id[0+:AXI_LOOK_BITS]                 ),
      .pop_i                        ( b_pop                                           )
    );

    // fifos to save w selection
    fifo_v3 #(
      .FALL_THROUGH( FALL_THROUGH ),
      .DEPTH       ( MAX_TRANS    ),
      .dtype       ( select_t     )
    ) i_w_fifo (
      .clk_i     ( clk_i                        ),
      .rst_ni    ( rst_ni                       ),
      .flush_i   ( 1'b0                         ),
      .testmode_i( test_i                       ),
      .full_o    ( w_fifo_full                  ),
      .empty_o   ( w_fifo_empty                 ),
      .usage_o   (                              ),
      .data_i    ( slv_aw_chan_select.aw_select ),
      .push_i    ( aw_push                      ), // controlled from proc_aw_chan
      .data_o    ( w_select                     ), // where the w beat should go
      .pop_i     ( w_fifo_pop                   )  // controlled from proc_w_chan
    );

    // aw demux
    for (genvar i = 0; i < NO_MST_PORTS; i++) begin
      assign mst_aw_chans_o[i] = aw_chan_select.aw_chan;
    end
    assign mst_aw_valids_o = (aw_valid) ? (1 << aw_chan_select.aw_select) : '0;
    assign aw_ready  = mst_aw_readies_i[aw_chan_select.aw_select];

    //--------------------------------------
    //  W Channel
    //--------------------------------------
    if (SPILL_W) begin : gen_spill_w
      spill_register #(
        .T       ( w_chan_t      )
      ) i_w_spill_reg(
        .clk_i   ( clk_i         ),
        .rst_ni  ( rst_ni        ),
        .valid_i ( slv_w_valid_i ),
        .ready_o ( slv_w_ready_o ),
        .data_i  ( slv_w_chan_i  ),
        .valid_o ( slv_w_valid   ),
        .ready_i ( slv_w_ready   ),
        .data_o  ( slv_w_chan    )
      );
    end else begin : gen_no_spill_w
      assign slv_w_chan    = slv_w_chan_i;
      assign slv_w_valid   = slv_w_valid_i;
      assign slv_w_ready_o = slv_w_ready;
    end
    always_comb begin : proc_w_chan
      // Axi W Channel
      for (int unsigned i = 0; i < NO_MST_PORTS; i++) begin
        mst_w_chans_o[i] = slv_w_chan;
      end
      // Axi handshakes
      mst_w_valids_o = '0;
      slv_w_ready    = 1'b0;
      // fifo control
      w_fifo_pop     = 1'b0;
      // Control
      // only do something if we expect some w beats and i_b_decerr_fifo is not full
      if (!w_fifo_empty) begin
        mst_w_valids_o[w_select] = slv_w_valid;
        slv_w_ready              = mst_w_readies_i[w_select];
        // when the last w beat occurs, pop the select fifo
        if (slv_w_valid && mst_w_readies_i[w_select] && slv_w_chan.last) begin
          w_fifo_pop = 1'b1;
        end
      end
    end

    //--------------------------------------
    //  B Channel
    //--------------------------------------
    // pop from id counter on outward transaction
    assign b_pop = slv_b_valid & slv_b_ready;
    // optional spill register
    if (SPILL_B) begin : gen_spill_b
      spill_register #(
        .T       ( b_chan_t      )
      ) i_b_spill_reg (
        .clk_i   ( clk_i         ),
        .rst_ni  ( rst_ni        ),
        .valid_i ( slv_b_valid   ),
        .ready_o ( slv_b_ready   ),
        .data_i  ( slv_b_chan    ),
        .valid_o ( slv_b_valid_o ),
        .ready_i ( slv_b_ready_i ),
        .data_o  ( slv_b_chan_o  )
      );
    end else begin : gen_no_spill_b
      assign slv_b_chan_o  = slv_b_chan;
      assign slv_b_valid_o = slv_b_valid;
      assign slv_b_ready   = slv_b_ready_i;
    end
    // Arbitration of the different b responses
    rr_arb_tree #(
      .NumIn    ( NO_MST_PORTS    ),
      .DataType ( b_chan_t        ),
      .AxiVldRdy( 1'b1            ),
      .LockIn   ( 1'b1            )
    ) i_b_mux (
      .clk_i  ( clk_i             ),
      .rst_ni ( rst_ni            ),
      .flush_i( 1'b0              ),
      .rr_i   ( '0                ),
      .req_i  ( mst_b_valids_i    ),
      .gnt_o  ( mst_b_readies_o   ),
      .data_i ( mst_b_chans_i     ),
      .gnt_i  ( slv_b_ready       ),
      .req_o  ( slv_b_valid       ),
      .data_o ( slv_b_chan        ),
      .idx_o  (                   )
    );

    //--------------------------------------
    //  AR Channel
    //--------------------------------------
    if (SPILL_AR) begin : gen_spill_ar
      ar_chan_select_t slv_ar_chan_select_in;
      assign slv_ar_chan_select_in.ar_chan   = slv_ar_chan_i;
      assign slv_ar_chan_select_in.ar_select = slv_ar_select_i;
      spill_register #(
        .T       ( ar_chan_select_t      )
      ) i_ar_spill_reg (
        .clk_i   ( clk_i                 ),
        .rst_ni  ( rst_ni                ),
        .valid_i ( slv_ar_valid_i        ),
        .ready_o ( slv_ar_ready_o        ),
        .data_i  ( slv_ar_chan_select_in ),
        .valid_o ( slv_ar_valid          ),
        .ready_i ( slv_ar_ready          ),
        .data_o  ( slv_ar_chan_select    )
      );
    end else begin : gen_no_spill_ar
      assign slv_ar_chan_select.ar_chan   = slv_ar_chan_i;
      assign slv_ar_chan_select.ar_select = slv_ar_select_i;
      assign slv_ar_valid                 = slv_ar_valid_i;
      assign slv_ar_ready_o               = slv_ar_ready;
    end

    always_comb begin : proc_ar_chan
      // Axi Handshakes
      slv_ar_ready    = 1'b0;
      ar_valid        = 1'b0;
      // lock ar_valid
      lock_ar_valid_n = lock_ar_valid_q;
      load_ar_lock    = 1'b0;
      // AR id counter
      ar_push         = 1'b0;
      // we had an arbitration decision, the valid is locked, wait for the transaction
      if (lock_ar_valid_q) begin
        ar_valid = 1'b1;
        // transaction
        if (ar_ready) begin
          slv_ar_ready    = 1'b1;
          ar_push         = 1'b1;
          lock_ar_valid_n = 1'b0;
          load_ar_lock    = 1'b1;
        end
      end else begin
        // can start handeling transaction, if id counter has space
        if (!ar_id_cnt_full) begin
          // there is a valid AR vector make the id lookup and go further, if it passes
          if (slv_ar_valid && (!ar_select_occupied ||
             (slv_ar_chan_select.ar_select == lookup_ar_select))) begin
            // connect the handshake
            ar_valid     = 1'b1;
            // on transaction
            if(ar_ready) begin
              slv_ar_ready = 1'b1;
              ar_push      = 1'b1;
            // no transaction, lock the valid decision!
            end else begin
              lock_ar_valid_n = 1'b1;
              load_ar_lock    = 1'b1;
            end
          end
        end
      end
    end

    // assign the data from one ar spill reg to the demux
    assign ar_chan_select = slv_ar_chan_select;

    // this ff is needed so that ar does not get deasserted if an atop gets injected
    always_ff @(posedge clk_i, negedge rst_ni) begin
      if (!rst_ni) begin
        lock_ar_valid_q <= '0;
      end else if (load_ar_lock) begin
        lock_ar_valid_q <= lock_ar_valid_n;
      end
    end

    axi_demux_id_counters #(
      .AXI_ID_BITS       ( AXI_LOOK_BITS    ),
      .COUNTER_WIDTH     ( ID_COUNTER_WIDTH ),
      .mst_port_select_t ( select_t         )
    ) i_ar_id_counter (
      .clk_i                        ( clk_i                                           ),
      .rst_ni                       ( rst_ni                                          ),
      .lookup_axi_id_i              ( slv_ar_chan_select.ar_chan.id[0+:AXI_LOOK_BITS] ),
      .lookup_mst_select_o          ( lookup_ar_select                                ),
      .lookup_mst_select_occupied_o ( ar_select_occupied                              ),
      .full_o                       ( ar_id_cnt_full                                  ),
      .inject_axi_id_i              ( slv_aw_chan_select.aw_chan.id[0+:AXI_LOOK_BITS] ),
      .inject_i                     ( atop_inject                                     ),
      .push_axi_id_i                ( slv_ar_chan_select.ar_chan.id[0+:AXI_LOOK_BITS] ),
      .push_mst_select_i            ( slv_ar_chan_select.ar_select                    ),
      .push_i                       ( ar_push                                         ),
      .pop_axi_id_i                 ( slv_r_chan.id[0+:AXI_LOOK_BITS]                 ),
      .pop_i                        ( r_pop                                           )
    );

    // ar demux
    for (genvar i = 0; i < NO_MST_PORTS; i++) begin
      assign mst_ar_chans_o[i] = ar_chan_select.ar_chan;
    end
    assign mst_ar_valids_o = (ar_valid) ? (1 << ar_chan_select.ar_select) : '0;
    assign ar_ready        = mst_ar_readies_i[ar_chan_select.ar_select];

    //--------------------------------------
    //  R Channel
    //--------------------------------------
    assign r_pop = slv_r_valid & slv_r_ready & slv_r_chan.last;
    // optional spill register
    if (SPILL_R) begin : gen_spill_r
      spill_register #(
        .T       ( r_chan_t      )
      ) i_r_spill_reg (
        .clk_i   ( clk_i         ),
        .rst_ni  ( rst_ni        ),
        .valid_i ( slv_r_valid   ),
        .ready_o ( slv_r_ready   ),
        .data_i  ( slv_r_chan    ),
        .valid_o ( slv_r_valid_o ),
        .ready_i ( slv_r_ready_i ),
        .data_o  ( slv_r_chan_o  )
      );
    end else begin : gen_no_spill_r
      assign slv_r_chan_o  = slv_r_chan;
      assign slv_r_valid_o = slv_r_valid;
      assign slv_r_ready   = slv_r_ready_i;
    end

    // Arbitration of the different r responses
    rr_arb_tree #(
      .NumIn    ( NO_MST_PORTS  ),
      .DataType ( r_chan_t      ),
      .AxiVldRdy( 1'b1          ),
      .LockIn   ( 1'b1          )
    ) i_r_mux (
      .clk_i  ( clk_i           ),
      .rst_ni ( rst_ni          ),
      .flush_i( 1'b0            ),
      .rr_i   ( '0              ),
      .req_i  ( mst_r_valids_i  ),
      .gnt_o  ( mst_r_readies_o ),
      .data_i ( mst_r_chans_i   ),
      .gnt_i  ( slv_r_ready     ),
      .req_o  ( slv_r_valid     ),
      .data_o ( slv_r_chan      ),
      .idx_o  (                 )
    );

// Validate parameters.
// pragma translate_off
`ifndef VERILATOR
    initial begin: validate_params
      no_mst_ports: assert (NO_MST_PORTS > 0) else
        $fatal(1, "axi_demux> The Number of slaves (NO_MST_PORTS) has to be at least 1");
      axi_id_bits:  assert (AXI_ID_WIDTH >= AXI_LOOK_BITS) else
        $fatal(1, "axi_demux> AXI_ID_BITS has to be equal or smaller than AXI_ID_WIDTH.");
    end
    aw_select: assert property( @(posedge clk_i) disable iff (~rst_ni)
                               (slv_aw_select_i < NO_MST_PORTS)) else
      $fatal(1, "axi_demux> slv_aw_select_i is %d: AW has selected a slave that is not defined.\
                 NO_MST_PORTS: %d", slv_aw_select_i, NO_MST_PORTS);
    ar_select: assert property( @(posedge clk_i) disable iff (~rst_ni)
                               (slv_aw_select_i < NO_MST_PORTS)) else
      $fatal(1, "slv_ar_select_i is %d: AR has selected a slave that is not defined.\
                 NO_MST_PORTS: %d", slv_ar_select_i, NO_MST_PORTS);
    aw_valid_stable: assert property( @(posedge clk_i) disable iff (~rst_ni)
                               (aw_valid && !aw_ready) |=> aw_valid) else
      $fatal(1, $sformatf("axi_demux> aw_valid was deasserted, when aw_ready = 0 in last cycle."));
    ar_valid_stable: assert property( @(posedge clk_i) disable iff (~rst_ni)
                               (ar_valid && !ar_ready) |=> ar_valid) else
      $fatal(1, $sformatf("axi_demux> ar_valid was deasserted, when ar_ready = 0 in last cycle."));
    aw_stable: assert property( @(posedge clk_i) disable iff (~rst_ni) (aw_valid && !aw_ready)
                               |=> (aw_chan_select == $past(aw_chan_select))) else
      $fatal(1, $sformatf("axi_demux> aw_chan_select unstable with valid set."));
    ar_stable: assert property( @(posedge clk_i) disable iff (~rst_ni) (ar_valid && !ar_ready)
                               |=> (ar_chan_select == $past(ar_chan_select))) else
      $fatal(1, $sformatf("axi_demux> aw_chan_select unstable with valid set."));
`endif
// pragma translate_on
  end
endmodule

module axi_demux_id_counters #(
  // the lower bits of the axi id that sould be considered, results in 2**AXI_ID_BITS counters
  parameter int unsigned AXI_ID_BITS       = 2,
  parameter int unsigned COUNTER_WIDTH     = 4,
  parameter type         mst_port_select_t = logic
) (
  input clk_i,   // Clock
  input rst_ni,  // Asynchronous reset active low
  // lookup
  input  logic [AXI_ID_BITS-1:0] lookup_axi_id_i,
  output mst_port_select_t       lookup_mst_select_o,
  output logic                   lookup_mst_select_occupied_o,
  // push
  output logic                   full_o,
  input  logic [AXI_ID_BITS-1:0] push_axi_id_i,
  input  mst_port_select_t       push_mst_select_i,
  input  logic                   push_i,
  // inject, for atops in ar channel
  input  logic [AXI_ID_BITS-1:0] inject_axi_id_i,
  input  logic                   inject_i,
  // pop
  input  logic [AXI_ID_BITS-1:0] pop_axi_id_i,
  input  logic                   pop_i
);
  localparam int unsigned NO_COUNTERS = 2**AXI_ID_BITS;
  typedef logic [COUNTER_WIDTH-1:0] cnt_t;

  // registers, gets loaded, when push_en
  mst_port_select_t [NO_COUNTERS-1:0] mst_select_q;

  // counter signals
  logic [NO_COUNTERS-1:0] push_en;
  logic [NO_COUNTERS-1:0] inject_en;
  logic [NO_COUNTERS-1:0] pop_en;

  logic [NO_COUNTERS-1:0] occupied;
  logic [NO_COUNTERS-1:0] cnt_full;

  //-----------------------------------
  // Lookup
  //-----------------------------------
  assign lookup_mst_select_o          = mst_select_q[lookup_axi_id_i];
  assign lookup_mst_select_occupied_o = occupied[lookup_axi_id_i];
  //-----------------------------------
  // Push and Pop
  //-----------------------------------
  assign push_en   = (push_i)   ? (1 << push_axi_id_i)   : '0;
  assign inject_en = (inject_i) ? (1 << inject_axi_id_i) : '0;
  assign pop_en    = (pop_i)    ? (1 << pop_axi_id_i)    : '0;
  assign full_o    = |cnt_full;
  // counters
  for (genvar i = 0; i < NO_COUNTERS; i++) begin : gen_counters
    logic cnt_en;
    logic cnt_down;
    cnt_t cnt_delta;
    cnt_t in_flight;
    logic overflow;
    always_comb begin : proc_control
      case ({push_en[i], inject_en[i], pop_en[i]})
        3'b001  : begin // pop_i = -1
          cnt_en    = 1'b1;
          cnt_down  = 1'b1;
          cnt_delta = cnt_t'(1);
        end
        3'b010  : begin // inject_i = +1
          cnt_en    = 1'b1;
          cnt_down  = 1'b0;
          cnt_delta = cnt_t'(1);
        end
     // 3'b011, inject_i & pop_i = 0 --> use default
        3'b100  : begin // push_i = +1
          cnt_en    = 1'b1;
          cnt_down  = 1'b0;
          cnt_delta = cnt_t'(1);
        end
     // 3'b101, push_i & pop_i = 0 --> use default
        3'b110  : begin // push_i & inject_i = +2
          cnt_en    = 1'b1;
          cnt_down  = 1'b0;
          cnt_delta = cnt_t'(2);
        end
        3'b111  : begin // push_i & inject_i & pop_i = +1
          cnt_en    = 1'b1;
          cnt_down  = 1'b0;
          cnt_delta = cnt_t'(1);
        end
        default : begin // do nothing to the counters
          cnt_en    = 1'b0;
          cnt_down  = 1'b0;
          cnt_delta = cnt_t'(0);
        end
      endcase
    end
    delta_counter #(
      .WIDTH           ( COUNTER_WIDTH ),
      .STICKY_OVERFLOW ( 1'b0         )
    ) i_in_flight_cnt (
      .clk_i      ( clk_i     ),
      .rst_ni     ( rst_ni    ),
      .clear_i    ( 1'b0      ),
      .en_i       ( cnt_en    ),
      .load_i     ( 1'b0      ),
      .down_i     ( cnt_down  ),
      .delta_i    ( cnt_delta ),
      .d_i        ( '0        ),
      .q_o        ( in_flight ),
      .overflow_o ( overflow  )
    );
    assign occupied[i] = |in_flight;
    assign cnt_full[i] = overflow | (&in_flight);
    cnt_underflow: assert property(
      @(posedge clk_i) disable iff (~rst_ni) (pop_en[i] |=> !overflow)) else
        $fatal(1, $sformatf("axi_demux > axi_demux_id_counters > Counter: %0d underflowed.\
                             The reason is probably a faulty Axi response.", i));
  end

  // flip flops that hold the selects
  always_ff @(posedge clk_i, negedge rst_ni) begin : proc_mst_port_sel_reg
    if (!rst_ni) begin
      mst_select_q <= '0;
    end else begin
      for (int unsigned i = 0; i < NO_COUNTERS; i++) begin
        if (push_en[i]) begin
          mst_select_q[i] <= push_mst_select_i;
        end
      end
    end
  end
endmodule

// interface wrapper
module axi_demux_wrap #(
  parameter int unsigned AXI_ID_WIDTH     = 0, // Synopsys DC requires a default value for param.
  parameter int unsigned AXI_ADDR_WIDTH   = 0,
  parameter int unsigned AXI_DATA_WIDTH   = 0,
  parameter int unsigned AXI_USER_WIDTH   = 0,
  parameter int unsigned NO_MST_PORTS     = 3,
  parameter int unsigned MAX_TRANS        = 8,
  parameter int unsigned ID_COUNTER_WIDTH = 4,
  parameter int unsigned AXI_LOOK_BITS    = 3,
  parameter bit          FALL_THROUGH     = 1'b0,
  parameter bit          SPILL_AW         = 1'b1,
  parameter bit          SPILL_AR         = 1'b1,
  // Dependent parameters, DO NOT OVERRIDE!
  parameter type         select_t         = logic [$clog2(NO_MST_PORTS)-1:0] // MST port select type
) (
  input  logic    clk_i,                 // Clock
  input  logic    rst_ni,                // Asynchronous reset active low
  input  logic    test_i,                // Testmode enable
  input  select_t slv_aw_select_i,       // has to be stable, when aw_valid
  input  select_t slv_ar_select_i,       // has to be stable, when ar_valid
  AXI_BUS.Slave   slv,                   // slave port
  AXI_BUS.Master  mst [NO_MST_PORTS-1:0] // master ports
);

  typedef logic [AXI_ID_WIDTH-1:0]     id_t;
  typedef logic [AXI_ADDR_WIDTH-1:0]   addr_t;
  typedef logic [AXI_DATA_WIDTH-1:0]   data_t;
  typedef logic [AXI_DATA_WIDTH/8-1:0] strb_t;
  typedef logic [AXI_USER_WIDTH-1:0]   user_t;
  `AXI_TYPEDEF_AW_CHAN_T ( aw_chan_t, addr_t, id_t,         user_t);
  `AXI_TYPEDEF_W_CHAN_T  (  w_chan_t, data_t,       strb_t, user_t);
  `AXI_TYPEDEF_B_CHAN_T  (  b_chan_t,         id_t,         user_t);
  `AXI_TYPEDEF_AR_CHAN_T ( ar_chan_t, addr_t, id_t,         user_t);
  `AXI_TYPEDEF_R_CHAN_T  (  r_chan_t, data_t, id_t,         user_t);
  `AXI_TYPEDEF_REQ_T     (     req_t, aw_chan_t, w_chan_t, ar_chan_t);
  `AXI_TYPEDEF_RESP_T    (    resp_t,  b_chan_t, r_chan_t) ;

  req_t                     slv_req;
  resp_t                    slv_resp;
  req_t  [NO_MST_PORTS-1:0] mst_req;
  resp_t [NO_MST_PORTS-1:0] mst_resp;

  // master ports
  // AW channel
  aw_chan_t [NO_MST_PORTS-1:0] mst_aw_chans;
  logic     [NO_MST_PORTS-1:0] mst_aw_valids;
  logic     [NO_MST_PORTS-1:0] mst_aw_readies;
  //  W channel
  w_chan_t  [NO_MST_PORTS-1:0] mst_w_chans;
  logic     [NO_MST_PORTS-1:0] mst_w_valids;
  logic     [NO_MST_PORTS-1:0] mst_w_readies;
  //  B channel
  b_chan_t  [NO_MST_PORTS-1:0] mst_b_chans;
  logic     [NO_MST_PORTS-1:0] mst_b_valids;
  logic     [NO_MST_PORTS-1:0] mst_b_readies;
  // AR channel
  ar_chan_t [NO_MST_PORTS-1:0] mst_ar_chans;
  logic     [NO_MST_PORTS-1:0] mst_ar_valids;
  logic     [NO_MST_PORTS-1:0] mst_ar_readies;
  //  R channel
  r_chan_t  [NO_MST_PORTS-1:0] mst_r_chans;
  logic     [NO_MST_PORTS-1:0] mst_r_valids;
  logic     [NO_MST_PORTS-1:0] mst_r_readies;

  `AXI_ASSIGN_TO_REQ    ( slv_req,  slv      );
  `AXI_ASSIGN_FROM_RESP ( slv,      slv_resp );

  for (genvar i = 0; i < NO_MST_PORTS; i++) begin : proc_assign_mst_ports
    assign mst_req[i].aw       = mst_aw_chans[i]      ;
    assign mst_req[i].aw_valid = mst_aw_valids[i]     ;
    assign mst_aw_readies[i]   = mst_resp[i].aw_ready ;

    assign mst_req[i].w        = mst_w_chans[i]       ;
    assign mst_req[i].w_valid  = mst_w_valids[i]      ;
    assign mst_w_readies[i]    = mst_resp[i].w_ready  ;

    assign mst_b_chans[i]      = mst_resp[i].b        ;
    assign mst_b_valids[i]     = mst_resp[i].b_valid  ;
    assign mst_req[i].b_ready  = mst_b_readies[i]     ;

    assign mst_req[i].ar       = mst_ar_chans[i]      ;
    assign mst_req[i].ar_valid = mst_ar_valids[i]     ;
    assign mst_ar_readies[i]   = mst_resp[i].ar_ready ;

    assign mst_r_chans[i]      = mst_resp[i].r        ;
    assign mst_r_valids[i]     = mst_resp[i].r_valid  ;
    assign mst_req[i].r_ready  = mst_r_readies[i]     ;

    `AXI_ASSIGN_FROM_REQ  ( mst[i]     , mst_req[i]  );
    `AXI_ASSIGN_TO_RESP   ( mst_resp[i], mst[i]      );
  end

  axi_demux #(
    .AXI_ID_WIDTH     ( AXI_ID_WIDTH     ), // ID Width
    .aw_chan_t        ( aw_chan_t        ), // AW Channel Type
    .w_chan_t         (  w_chan_t        ), //  W Channel Type
    .b_chan_t         (  b_chan_t        ), //  B Channel Type
    .ar_chan_t        ( ar_chan_t        ), // AR Channel Type
    .r_chan_t         (  r_chan_t        ), //  R Channel Type
    .NO_MST_PORTS     ( NO_MST_PORTS     ),
    .MAX_TRANS        ( MAX_TRANS        ),
    .ID_COUNTER_WIDTH ( ID_COUNTER_WIDTH ),
    .AXI_LOOK_BITS    ( AXI_LOOK_BITS    ),
    .FALL_THROUGH     ( FALL_THROUGH     ),
    .SPILL_AW        ( SPILL_AW        ),
    .SPILL_AR        ( SPILL_AR        )
  ) i_axi_demux (
    .clk_i,   // Clock
    .rst_ni,  // Asynchronous reset active low
    .test_i,  // Testmode enable
    // slave port
    // AW channel
    .slv_aw_chan_i    ( slv_req.aw        ),
    .slv_aw_select_i  ( slv_aw_select_i   ), // Has to be cycle stable when slv_aw_valid_i
    .slv_aw_valid_i   ( slv_req.aw_valid  ),
    .slv_aw_ready_o   ( slv_resp.aw_ready ),
    //  W channel
    .slv_w_chan_i     ( slv_req.w         ),
    .slv_w_valid_i    ( slv_req.w_valid   ),
    .slv_w_ready_o    ( slv_resp.w_ready  ),
    //  B channel
    .slv_b_chan_o     ( slv_resp.b        ),
    .slv_b_valid_o    ( slv_resp.b_valid  ),
    .slv_b_ready_i    ( slv_req.b_ready   ),
    // AR channel
    .slv_ar_chan_i    ( slv_req.ar        ),
    .slv_ar_select_i  ( slv_ar_select_i   ), // Has to be cycle stable when slv_ar_valid_i
    .slv_ar_valid_i   ( slv_req.ar_valid  ),
    .slv_ar_ready_o   ( slv_resp.ar_ready ),
    //  R channel
    .slv_r_chan_o     ( slv_resp.r        ),
    .slv_r_valid_o    ( slv_resp.r_valid  ),
    .slv_r_ready_i    ( slv_req.r_ready   ),
    // master ports
    // AW channel
    .mst_aw_chans_o   ( mst_aw_chans      ),
    .mst_aw_valids_o  ( mst_aw_valids     ),
    .mst_aw_readies_i ( mst_aw_readies    ),
     //  W channel
    .mst_w_chans_o    ( mst_w_chans       ),
    .mst_w_valids_o   ( mst_w_valids      ),
    .mst_w_readies_i  ( mst_w_readies     ),
     //  B channel
    .mst_b_chans_i    ( mst_b_chans       ),
    .mst_b_valids_i   ( mst_b_valids      ),
    .mst_b_readies_o  ( mst_b_readies     ),
     // AR channel
    .mst_ar_chans_o   ( mst_ar_chans      ),
    .mst_ar_valids_o  ( mst_ar_valids     ),
    .mst_ar_readies_i ( mst_ar_readies    ),
     //  R channel
    .mst_r_chans_i    ( mst_r_chans       ),
    .mst_r_valids_i   ( mst_r_valids      ),
    .mst_r_readies_o  ( mst_r_readies     )
);
endmodule
