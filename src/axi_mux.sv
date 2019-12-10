// Copyright (c) 2019 ETH Zurich, University of Bologna
//
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// Author: Wolfgang Roenninger <wroennin@ethz.ch>

// AXI Multiplexer: This module multiplexes the AXI4 slave ports down to one master port.
// The MSBs of each AXI ID must contain the index of the corresponding slave port.
// Responses are switched based on these bits.  For example, with 4 slave ports
// a response with ID `6'b100110` will be forwarded to slave port 2 (`2'b10`).

// register macros
`include "common_cells/registers.svh"

module axi_mux #(
  parameter int unsigned AxiIDWidth  = 1,
  parameter type         aw_chan_t   = logic, // AW Channel Type
  parameter type         w_chan_t    = logic, //  W Channel Type
  parameter type         b_chan_t    = logic, //  B Channel Type
  parameter type         ar_chan_t   = logic, // AR Channel Type
  parameter type         r_chan_t    = logic, //  R Channel Type
  parameter int unsigned NoSlvPorts  = 1,     // Number of slave ports
  // Maximum number of outstanding transactions per write
  parameter int unsigned MaxWTrans   = 8,
  // If enabled, this multiplexer is purely combinatorial
  parameter bit          FallThrough = 1'b0,
  // add spill register on write master ports, adds a cycle latency on write channels
  parameter bit          SpillAw     = 1'b1,
  parameter bit          SpillW      = 1'b0,
  parameter bit          SpillB      = 1'b0,
  // add spill register on read master ports, adds a cycle latency on read channels
  parameter bit          SpillAr     = 1'b1,
  parameter bit          SpillR      = 1'b0
) (
  input  logic                      clk_i,    // Clock
  input  logic                      rst_ni,   // Asynchronous reset active low
  input  logic                      test_i,   // Test Mode enable
  // slave ports (AXI inputs), connect master modules here
  // AW channel
  input  aw_chan_t [NoSlvPorts-1:0] slv_aw_chans_i,
  input  logic     [NoSlvPorts-1:0] slv_aw_valids_i,
  output logic     [NoSlvPorts-1:0] slv_aw_readies_o,
  //  W channel
  input  w_chan_t  [NoSlvPorts-1:0] slv_w_chans_i,
  input  logic     [NoSlvPorts-1:0] slv_w_valids_i,
  output logic     [NoSlvPorts-1:0] slv_w_readies_o,
  //  B channel
  output b_chan_t  [NoSlvPorts-1:0] slv_b_chans_o,
  output logic     [NoSlvPorts-1:0] slv_b_valids_o,
  input  logic     [NoSlvPorts-1:0] slv_b_readies_i,
  // AR channel
  input  ar_chan_t [NoSlvPorts-1:0] slv_ar_chans_i,
  input  logic     [NoSlvPorts-1:0] slv_ar_valids_i,
  output logic     [NoSlvPorts-1:0] slv_ar_readies_o,
  //  R channel
  output r_chan_t  [NoSlvPorts-1:0] slv_r_chans_o,
  output logic     [NoSlvPorts-1:0] slv_r_valids_o,
  input  logic     [NoSlvPorts-1:0] slv_r_readies_i,
  // master port (AXI outputs), connect slave modules here
  // AW channel
  output aw_chan_t                  mst_aw_chan_o,
  output logic                      mst_aw_valid_o,
  input  logic                      mst_aw_ready_i,
  //  W channel
  output w_chan_t                   mst_w_chan_o,
  output logic                      mst_w_valid_o,
  input  logic                      mst_w_ready_i,
  //  B channel
  input  b_chan_t                   mst_b_chan_i,
  input  logic                      mst_b_valid_i,
  output logic                      mst_b_ready_o,
  // AR channel
  output ar_chan_t                  mst_ar_chan_o,
  output logic                      mst_ar_valid_o,
  input  logic                      mst_ar_ready_i,
  //  R channel
  input  r_chan_t                   mst_r_chan_i,
  input  logic                      mst_r_valid_i,
  output logic                      mst_r_ready_o
);
  // pass through if only one slave port
  if (NoSlvPorts == 32'h1) begin : gen_no_mux
    // AW channel
    assign mst_aw_chan_o       = slv_aw_chans_i[0];
    assign mst_aw_valid_o      = slv_aw_valids_i[0];
    assign slv_aw_readies_o[0] = mst_aw_ready_i;
    // W channel
    assign mst_w_chan_o        = slv_w_chans_i[0];
    assign mst_w_valid_o       = slv_w_valids_i[0];
    assign slv_w_readies_o[0]  = mst_w_ready_i;
    // B channel
    assign slv_b_chans_o[0]    = mst_b_chan_i;
    assign slv_b_valids_o[0]   = mst_b_valid_i;
    assign mst_b_ready_o       = slv_b_readies_i[0];
    // AR channel
    assign mst_ar_chan_o       = slv_ar_chans_i[0];
    assign mst_ar_valid_o      = slv_ar_valids_i[0];
    assign slv_ar_readies_o[0] = mst_ar_ready_i;
    // R channel
    assign slv_r_chans_o[0]    = mst_r_chan_i;
    assign slv_r_valids_o[0]   = mst_r_valid_i;
    assign mst_r_ready_o       = slv_r_readies_i[0];

  // other non degenerate cases
  end else begin : gen_mux

    // typedef for the w_fifo
    localparam int unsigned MstIdxBits = $clog2(NoSlvPorts);
    // these are for finding the right bit of the return ID for the switching
    localparam int unsigned MstIdx     = AxiIDWidth - MstIdxBits;

    typedef logic [MstIdxBits-1:0] switch_id_t;

    // AW channel
    aw_chan_t   mst_aw_chan;
    logic       mst_aw_valid, mst_aw_ready;

    // AW master handshake internal, so that we are able to stall, if w_fifo is full
    logic       aw_valid,     aw_ready;

    // FF to lock the AW valid signal, when a new arbitration decision is made the decision
    // gets pushed into the W FIFO, when it now stalls prevent subsequent pushing
    // This FF removes AW to W dependency
    logic       lock_aw_valid_d, lock_aw_valid_q;
    logic       load_aw_lock;

    // signals for the FIFO that holds the last switching decision of the AW channel
    logic       w_fifo_full,  w_fifo_empty;
    logic       w_fifo_push,  w_fifo_pop;
    switch_id_t w_fifo_data;

    // W channel spill reg
    w_chan_t    mst_w_chan;
    logic       mst_w_valid,  mst_w_ready;

    // master ID in the b_id
    switch_id_t switch_b_id;

    // B channel spill reg
    b_chan_t    mst_b_chan;
    logic       mst_b_valid;

    // AR channel for when spill is enabled
    ar_chan_t   mst_ar_chan;
    logic       ar_valid,     ar_ready;

    // master ID in the r_id
    switch_id_t switch_r_id;

    // R channel spill reg
    r_chan_t    mst_r_chan;
    logic       mst_r_valid;

    //--------------------------------------
    // AW Channel
    //--------------------------------------
    rr_arb_tree #(
      .NumIn    ( NoSlvPorts ),
      .DataType ( aw_chan_t    ),
      .AxiVldRdy( 1'b1         ),
      .LockIn   ( 1'b1         )
    ) i_aw_arbiter (
      .clk_i  ( clk_i            ),
      .rst_ni ( rst_ni           ),
      .flush_i( 1'b0             ),
      .rr_i   ( '0               ),
      .req_i  ( slv_aw_valids_i  ),
      .gnt_o  ( slv_aw_readies_o ),
      .data_i ( slv_aw_chans_i   ),
      .gnt_i  ( aw_ready         ),
      .req_o  ( aw_valid         ),
      .data_o ( mst_aw_chan      ),
      .idx_o  (                  )
    );

    // control of the AW channel
    always_comb begin
      // default assignments
      lock_aw_valid_d = lock_aw_valid_q;
      load_aw_lock    = 1'b0;
      w_fifo_push     = 1'b0;
      mst_aw_valid    = 1'b0;
      aw_ready        = 1'b0;
      // had a downstream stall, be valid and send the AW along
      if (lock_aw_valid_q) begin
        mst_aw_valid = 1'b1;
        // transaction
        if (mst_aw_ready) begin
          aw_ready        = 1'b1;
          lock_aw_valid_d = 1'b0;
          load_aw_lock    = 1'b1;
        end
      end else begin
        if (!w_fifo_full && aw_valid) begin
          mst_aw_valid = 1'b1;
          w_fifo_push = 1'b1;
          if (mst_aw_ready) begin
            aw_ready = 1'b1;
          end else begin
            // go to lock if transaction not in this cycle
            lock_aw_valid_d = 1'b1;
            load_aw_lock    = 1'b1;
          end
        end
      end
    end

    `FFLARN(lock_aw_valid_q, lock_aw_valid_d, load_aw_lock, '0, clk_i, rst_ni)

    fifo_v3 #(
      .FALL_THROUGH ( FallThrough ),
      .DEPTH        ( MaxWTrans  ),
      .dtype        ( switch_id_t  )
    ) i_w_fifo (
      .clk_i     ( clk_i                              ),
      .rst_ni    ( rst_ni                             ),
      .flush_i   ( 1'b0                               ),
      .testmode_i( test_i                             ),
      .full_o    ( w_fifo_full                        ),
      .empty_o   ( w_fifo_empty                       ),
      .usage_o   (                                    ),
      .data_i    ( mst_aw_chan.id[MstIdx+:MstIdxBits] ),
      .push_i    ( w_fifo_push                        ),
      .data_o    ( w_fifo_data                        ),
      .pop_i     ( w_fifo_pop                         )
    );

    spill_register #(
      .T       ( aw_chan_t      ),
      .Bypass  ( ~SpillAw       ) // Param indicated that we want a spill reg
    ) i_aw_spill_reg (
      .clk_i   ( clk_i          ),
      .rst_ni  ( rst_ni         ),
      .valid_i ( mst_aw_valid   ),
      .ready_o ( mst_aw_ready   ),
      .data_i  ( mst_aw_chan    ),
      .valid_o ( mst_aw_valid_o ),
      .ready_i ( mst_aw_ready_i ),
      .data_o  ( mst_aw_chan_o  )
    );

    //--------------------------------------
    // W Channel
    //--------------------------------------
    // mux
    assign mst_w_chan = slv_w_chans_i[w_fifo_data];
    always_comb begin
      // default assignments
      mst_w_valid     = 1'b0;
      slv_w_readies_o = '0;
      w_fifo_pop      = 1'b0;
      // control
      if (!w_fifo_empty) begin
        // connect the handshake
        mst_w_valid                  = slv_w_valids_i[w_fifo_data];
        slv_w_readies_o[w_fifo_data] = mst_w_ready;
        // pop FIFO on a last transaction
        w_fifo_pop = slv_w_valids_i[w_fifo_data] & mst_w_ready & mst_w_chan.last;
      end
    end

    spill_register #(
      .T       ( w_chan_t      ),
      .Bypass  ( ~SpillW       )
    ) i_w_spill_reg (
      .clk_i   ( clk_i         ),
      .rst_ni  ( rst_ni        ),
      .valid_i ( mst_w_valid   ),
      .ready_o ( mst_w_ready   ),
      .data_i  ( mst_w_chan    ),
      .valid_o ( mst_w_valid_o ),
      .ready_i ( mst_w_ready_i ),
      .data_o  ( mst_w_chan_o  )
    );

    //--------------------------------------
    // B Channel
    //--------------------------------------
    // replicate B channels
    assign slv_b_chans_o = {NoSlvPorts{mst_b_chan}};
    // control B channel handshake
    assign switch_b_id    = mst_b_chan.id[MstIdx+:MstIdxBits];
    assign slv_b_valids_o = (mst_b_valid) ? (1 << switch_b_id) : '0;

    spill_register #(
      .T       ( b_chan_t      ),
      .Bypass  ( ~SpillB       )
    ) i_b_spill_reg (
      .clk_i   ( clk_i                        ),
      .rst_ni  ( rst_ni                       ),
      .valid_i ( mst_b_valid_i                ),
      .ready_o ( mst_b_ready_o                ),
      .data_i  ( mst_b_chan_i                 ),
      .valid_o ( mst_b_valid                  ),
      .ready_i ( slv_b_readies_i[switch_b_id] ),
      .data_o  ( mst_b_chan                   )
    );

    //--------------------------------------
    // AR Channel
    //--------------------------------------
    rr_arb_tree #(
      .NumIn    ( NoSlvPorts ),
      .DataType ( ar_chan_t  ),
      .AxiVldRdy( 1'b1       ),
      .LockIn   ( 1'b1       )
    ) i_ar_arbiter (
      .clk_i  ( clk_i            ),
      .rst_ni ( rst_ni           ),
      .flush_i( 1'b0             ),
      .rr_i   ( '0               ),
      .req_i  ( slv_ar_valids_i  ),
      .gnt_o  ( slv_ar_readies_o ),
      .data_i ( slv_ar_chans_i   ),
      .gnt_i  ( ar_ready         ),
      .req_o  ( ar_valid         ),
      .data_o ( mst_ar_chan      ),
      .idx_o  (                  )
    );

    spill_register #(
      .T       ( ar_chan_t      ),
      .Bypass  ( ~SpillAr       )
    ) i_ar_spill_reg (
      .clk_i   ( clk_i          ),
      .rst_ni  ( rst_ni         ),
      .valid_i ( ar_valid       ),
      .ready_o ( ar_ready       ),
      .data_i  ( mst_ar_chan    ),
      .valid_o ( mst_ar_valid_o ),
      .ready_i ( mst_ar_ready_i ),
      .data_o  ( mst_ar_chan_o  )
    );

    //--------------------------------------
    // R Channel
    //--------------------------------------
    // replicate R channels
    assign slv_r_chans_o = {NoSlvPorts{mst_r_chan}};
    // R channel handshake control
    assign switch_r_id    = mst_r_chan.id[MstIdx+:MstIdxBits];
    assign slv_r_valids_o = (mst_r_valid) ? (1 << switch_r_id) : '0;

    spill_register #(
      .T       ( r_chan_t      ),
      .Bypass  ( ~SpillR       )
    ) i_r_spill_reg (
      .clk_i   ( clk_i                        ),
      .rst_ni  ( rst_ni                       ),
      .valid_i ( mst_r_valid_i                ),
      .ready_o ( mst_r_ready_o                ),
      .data_i  ( mst_r_chan_i                 ),
      .valid_o ( mst_r_valid                  ),
      .ready_i ( slv_r_readies_i[switch_r_id] ),
      .data_o  ( mst_r_chan                   )
    );
  end
endmodule

// interface wrap
`include "axi/assign.svh"
`include "axi/typedef.svh"
module axi_mux_wrap #(
  parameter int unsigned AxiIDWidth   = 0, // Synopsys DC requires a default value for parameters.
  parameter int unsigned AxiAddrWidth = 0,
  parameter int unsigned AxiDataWidth = 0,
  parameter int unsigned AxiUserWidth = 0,
  parameter int unsigned NoSlvPorts   = 0, // Number of slave ports
  // Maximum number of outstanding transactions per write
  parameter int unsigned MaxWTrans    = 8,
  // if enabled, this multiplexer is purely combinatorial
  parameter bit          FallThrough  = 1'b0,
  // add spill register on write master ports, adds a cycle latency on write channels
  parameter bit          SpillAw      = 1'b1,
  parameter bit          SpillW       = 1'b0,
  parameter bit          SpillB       = 1'b0,
  // add spill register on read master ports, adds a cycle latency on read channels
  parameter bit          SpillAr      = 1'b1,
  parameter bit          SpillR       = 1'b0
) (
  input  logic   clk_i,                // Clock
  input  logic   rst_ni,               // Asynchronous reset active low
  input  logic   test_i,               // Testmode enable
  AXI_BUS.Slave  slv [NoSlvPorts-1:0], // slave ports
  AXI_BUS.Master mst                   // master port
);

  typedef logic [AxiIDWidth-1:0]       id_t;
  typedef logic [AxiAddrWidth-1:0]   addr_t;
  typedef logic [AxiDataWidth-1:0]   data_t;
  typedef logic [AxiDataWidth/8-1:0] strb_t;
  typedef logic [AxiUserWidth-1:0]   user_t;
  `AXI_TYPEDEF_AW_CHAN_T( aw_chan_t, addr_t, id_t,         user_t);
  `AXI_TYPEDEF_W_CHAN_T (  w_chan_t, data_t,       strb_t, user_t);
  `AXI_TYPEDEF_B_CHAN_T (  b_chan_t,         id_t,         user_t);
  `AXI_TYPEDEF_AR_CHAN_T( ar_chan_t, addr_t, id_t,         user_t);
  `AXI_TYPEDEF_R_CHAN_T (  r_chan_t, data_t, id_t,         user_t);
  `AXI_TYPEDEF_REQ_T    (     req_t, aw_chan_t, w_chan_t, ar_chan_t);
  `AXI_TYPEDEF_RESP_T   (    resp_t,  b_chan_t, r_chan_t) ;

  req_t  [NoSlvPorts-1:0] slv_req;
  resp_t [NoSlvPorts-1:0] slv_resp;
  req_t                   mst_req;
  resp_t                  mst_resp;

  // master ports
  // AW channel
  aw_chan_t [NoSlvPorts-1:0] slv_aw_chans;
  logic     [NoSlvPorts-1:0] slv_aw_valids;
  logic     [NoSlvPorts-1:0] slv_aw_readies;
  //  W channel
  w_chan_t  [NoSlvPorts-1:0] slv_w_chans;
  logic     [NoSlvPorts-1:0] slv_w_valids;
  logic     [NoSlvPorts-1:0] slv_w_readies;
  //  B channel
  b_chan_t  [NoSlvPorts-1:0] slv_b_chans;
  logic     [NoSlvPorts-1:0] slv_b_valids;
  logic     [NoSlvPorts-1:0] slv_b_readies;
  // AR channel
  ar_chan_t [NoSlvPorts-1:0] slv_ar_chans;
  logic     [NoSlvPorts-1:0] slv_ar_valids;
  logic     [NoSlvPorts-1:0] slv_ar_readies;
  //  R channel
  r_chan_t  [NoSlvPorts-1:0] slv_r_chans;
  logic     [NoSlvPorts-1:0] slv_r_valids;
  logic     [NoSlvPorts-1:0] slv_r_readies;

  for (genvar i = 0; i < NoSlvPorts; i++) begin : gen_assign_slv_ports
    `AXI_ASSIGN_TO_REQ    ( slv_req[i],  slv[i]      );
    `AXI_ASSIGN_FROM_RESP ( slv[i],      slv_resp[i] );

    assign slv_aw_chans[i]      = slv_req[i].aw       ;
    assign slv_aw_valids[i]     = slv_req[i].aw_valid ;
    assign slv_resp[i].aw_ready = slv_aw_readies[i]   ;

    assign slv_w_chans[i]       = slv_req[i].w        ;
    assign slv_w_valids[i]      = slv_req[i].w_valid  ;
    assign slv_resp[i].w_ready  = slv_w_readies[i]    ;

    assign slv_resp[i].b        = slv_b_chans[i]      ;
    assign slv_resp[i].b_valid  = slv_b_valids[i]     ;
    assign slv_b_readies[i]     = slv_req[i].b_ready  ;

    assign slv_ar_chans[i]      = slv_req[i].ar       ;
    assign slv_ar_valids[i]     = slv_req[i].ar_valid ;
    assign slv_resp[i].ar_ready = slv_ar_readies[i]   ;

    assign slv_resp[i].r        = slv_r_chans[i]      ;
    assign slv_resp[i].r_valid  = slv_r_valids[i]     ;
    assign slv_r_readies[i]     = slv_req[i].r_ready  ;
  end

  `AXI_ASSIGN_FROM_REQ  ( mst     , mst_req  );
  `AXI_ASSIGN_TO_RESP   ( mst_resp, mst      );

  axi_mux #(
    .NoSlvPorts  ( NoSlvPorts  ), // Number of slave ports
    .AxiIDWidth  ( AxiIDWidth  ),
    .aw_chan_t   ( aw_chan_t   ), // AW Channel Type
    .w_chan_t    (  w_chan_t   ), //  W Channel Type
    .b_chan_t    (  b_chan_t   ), //  B Channel Type
    .ar_chan_t   ( ar_chan_t   ), // AR Channel Type
    .r_chan_t    (  r_chan_t   ), //  R Channel Type
    .MaxWTrans   ( MaxWTrans   ),
    .FallThrough ( FallThrough ),
    .SpillAw     ( SpillAw     ),
    .SpillW      ( SpillW      ),
    .SpillB      ( SpillB      ),
    .SpillAr     ( SpillAr     ),
    .SpillR      ( SpillR      )
  ) i_axi_mux (
    .clk_i            ( clk_i             ), // Clock
    .rst_ni           ( rst_ni            ), // Asynchronous reset active low
    .test_i           ( test_i            ), // Test Mode enable
    .slv_aw_chans_i   ( slv_aw_chans      ),
    .slv_aw_valids_i  ( slv_aw_valids     ),
    .slv_aw_readies_o ( slv_aw_readies    ),
    .slv_w_chans_i    ( slv_w_chans       ),
    .slv_w_valids_i   ( slv_w_valids      ),
    .slv_w_readies_o  ( slv_w_readies     ),
    .slv_b_chans_o    ( slv_b_chans       ),
    .slv_b_valids_o   ( slv_b_valids      ),
    .slv_b_readies_i  ( slv_b_readies     ),
    .slv_ar_chans_i   ( slv_ar_chans      ),
    .slv_ar_valids_i  ( slv_ar_valids     ),
    .slv_ar_readies_o ( slv_ar_readies    ),
    .slv_r_chans_o    ( slv_r_chans       ),
    .slv_r_valids_o   ( slv_r_valids      ),
    .slv_r_readies_i  ( slv_r_readies     ),
    .mst_aw_chan_o    ( mst_req.aw        ),
    .mst_aw_valid_o   ( mst_req.aw_valid  ),
    .mst_aw_ready_i   ( mst_resp.aw_ready ),
    .mst_w_chan_o     ( mst_req.w         ),
    .mst_w_valid_o    ( mst_req.w_valid   ),
    .mst_w_ready_i    ( mst_resp.w_ready  ),
    .mst_b_chan_i     ( mst_resp.b        ),
    .mst_b_valid_i    ( mst_resp.b_valid  ),
    .mst_b_ready_o    ( mst_req.b_ready   ),
    .mst_ar_chan_o    ( mst_req.ar        ),
    .mst_ar_valid_o   ( mst_req.ar_valid  ),
    .mst_ar_ready_i   ( mst_resp.ar_ready ),
    .mst_r_chan_i     ( mst_resp.r        ),
    .mst_r_valid_i    ( mst_resp.r_valid  ),
    .mst_r_ready_o    ( mst_req.r_ready   )
  );
endmodule
