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

// axi xbar tb utility

package tb_axi_xbar_pkg;

  class axi_xbar_monitor #(
    parameter int unsigned AxiAddrWidth,
    parameter int unsigned AxiDataWidth,
    parameter int unsigned AxiIdWidthMasters,
    parameter int unsigned AxiIdWidthSlaves,
    parameter int unsigned AxiUserWidth,
    parameter int unsigned NoMasters,
    parameter int unsigned NoSlaves,
    parameter int unsigned NoAddrRules,
    parameter type         rule_t,
    parameter rule_t [NoAddrRules-1:0] AddrMap,
      // Stimuli application and test time
    parameter time  TimeTest
  );
    typedef logic [AxiIdWidthMasters-1:0] mst_axi_id_t;
    typedef logic [AxiIdWidthSlaves-1:0]  slv_axi_id_t;
    typedef logic [AxiAddrWidth-1:0]      axi_addr_t;

    typedef logic [$clog2(NoMasters)-1:0] idx_mst_t;
    typedef int unsigned                  idx_slv_t; // from rule_t

    typedef struct packed {
      mst_axi_id_t mst_axi_id;
      logic        last;
    } master_exp_t;
    typedef struct packed {
      slv_axi_id_t   slv_axi_id;
      axi_addr_t     slv_axi_addr;
      axi_pkg::len_t slv_axi_len;
    } exp_ax_t;
    typedef struct packed {
      slv_axi_id_t slv_axi_id;
      logic        last;
    } slave_exp_t;


    typedef rand_id_queue_pkg::rand_id_queue #(
      .data_t   ( master_exp_t      ),
      .ID_WIDTH ( AxiIdWidthMasters )
    ) master_exp_queue_t;
    typedef rand_id_queue_pkg::rand_id_queue #(
      .data_t   ( exp_ax_t         ),
      .ID_WIDTH ( AxiIdWidthSlaves )
    ) ax_queue_t;


    typedef rand_id_queue_pkg::rand_id_queue #(
      .data_t   ( slave_exp_t      ),
      .ID_WIDTH ( AxiIdWidthSlaves )
    ) slave_exp_queue_t;

    //-----------------------------------------
    // Monitoring virtual interfaces
    //-----------------------------------------
    virtual AXI_BUS_DV #(
      .AXI_ADDR_WIDTH ( AxiAddrWidth      ),
      .AXI_DATA_WIDTH ( AxiDataWidth      ),
      .AXI_ID_WIDTH   ( AxiIdWidthMasters ),
      .AXI_USER_WIDTH ( AxiUserWidth      )
    ) masters_axi [NoMasters-1:0];
    virtual AXI_BUS_DV #(
      .AXI_ADDR_WIDTH ( AxiAddrWidth      ),
      .AXI_DATA_WIDTH ( AxiDataWidth      ),
      .AXI_ID_WIDTH   ( AxiIdWidthSlaves  ),
      .AXI_USER_WIDTH ( AxiUserWidth      )
    ) slaves_axi [NoSlaves-1:0];
    //-----------------------------------------
    // Queues and FIFOs to hold the expected ids
    //-----------------------------------------
    // Write transactions
    ax_queue_t         exp_aw_queue [NoSlaves-1:0];
    slave_exp_t        exp_w_fifo   [NoSlaves-1:0][$];
    slave_exp_t        act_w_fifo   [NoSlaves-1:0][$];
    master_exp_queue_t exp_b_queue  [NoMasters-1:0];

    // Read transactions

    master_exp_queue_t exp_r_queue  [NoMasters-1:0];





    // Masters
    master_exp_t       mst_exp_w_fifo  [NoMasters-1:0][$];
    master_exp_t       mst_w_buffer    [NoMasters-1:0][$];

    // Slaves
    slave_exp_ax_queue_t  slv_exp_aw_queue  [NoSlaves-1:0];
    slave_exp_ax_queue_t  slv_exp_ar_queue  [NoSlaves-1:0];
    //-----------------------------------------
    // Bookkeeping
    //-----------------------------------------
    longint unsigned tests_expected;
    longint unsigned tests_conducted;
    longint unsigned tests_failed;
    semaphore        cnt_sem;




    //-----------------------------------------
    // Constructor
    //-----------------------------------------
    function new(
      virtual AXI_BUS_DV #(
        .AXI_ADDR_WIDTH ( AxiAddrWidth      ),
        .AXI_DATA_WIDTH ( AxiDataWidth      ),
        .AXI_ID_WIDTH   ( AxiIdWidthMasters ),
        .AXI_USER_WIDTH ( AxiUserWidth      )
      ) axi_masters_vif [NoMasters-1:0],
      virtual AXI_BUS_DV #(
        .AXI_ADDR_WIDTH ( AxiAddrWidth      ),
        .AXI_DATA_WIDTH ( AxiDataWidth      ),
        .AXI_ID_WIDTH   ( AxiIdWidthSlaves  ),
        .AXI_USER_WIDTH ( AxiUserWidth      )
      ) axi_slaves_vif [NoSlaves-1:0]
    );
      begin
        this.masters_axi     = axi_masters_vif;
        this.slaves_axi      = axi_slaves_vif;
        this.tests_expected  = 0;
        this.tests_conducted = 0;
        this.tests_failed    = 0;
        for (int unsigned i = 0; i < NoMasters; i++) begin
          this.mst_exp_b_queue[i] = new;
          this.mst_exp_r_queue[i] = new;
        end
        for (int unsigned i = 0; i < NoSlaves; i++) begin
          this.slv_exp_aw_queue[i] = new;
          this.slv_exp_ar_queue[i] = new;
        end
        this.cnt_sem = new(1);
      end
    endfunction

    // when start the testing
    task cycle_start;
      #TimeTest;
    endtask

    // when is cycle finished
    task cycle_end;
      @(posedge masters_axi[0].clk_i);
    endtask

    task automatic monitor_mst_aw(input int unsigned i);
      idx_slv_t    to_slave_idx;
      exp_ax_t     exp_aw;
      slv_axi_id_t exp_aw_id;
      bit          decerr;

      master_exp_t exp_b;

      if (masters_axi[i].aw_valid && masters_axi[i].aw_ready) begin
        // check if it should go to a decerror
        decerr = 1'b1;
        for (int unsigned j = 0; j < NoAddrRules; j++) begin
          if ((mst_axi_addr >= AddrMap[j].start_addr) && (mst_axi_addr < AddrMap[j].end_addr)) begin
            to_slave_idx = idx_slv_t'(AddrMap[j].mst_port_idx);
            decerr = 1'b0;
          end
        end
        // populate the expected b queue anyway
        exp_b = '{mst_axi_id: masters_axi[i].aw_id, last: 1'b1};
        this.exp_b_queue[i].push(masters_axi[i].aw_id, exp_b);
        incr_expected_tests(1);
        // inject expected r beats on this id, if it is an atop
        if(masters_axi[i].aw_atop[5]) begin
          // push the required r beats into the right fifo (reuse the exp_b variable)
          for (int unsigned j = 0; j <= mst_axi_len; j++) begin
            exp_b = (j == masters_axi[i].aw_len) ?
                '{mst_axi_id: mst_axi_id, last: 1'b1} : '{mst_axi_id: mst_axi_id, last: 1'b0};
            this.exp_r_queue[i].push(masters_axi[i].aw_id, exp_b);
            incr_expected_tests(1);
          end
        end
        // send the exp aw beat down into the queue of the slave when no decerror
        if (!decerror) begin
          exp_aw_id = '{idx_mst_t'(i), masters_axi[i].aw_id};
          exp_aw = '{slv_axi_id:   exp_aw_id,
                     slv_axi_addr: masters_axi[i].aw_addr,
                     slv_axi_len:  masters_axi[i].aw_len   };
          this.exp_aw_queue[to_slave_idx].push(exp_aw_id, exp_aw);
          incr_expected_tests(3);
          $display("%0tns > Master %0d: AW to Slave %0d: Axi ID: %b",
              $time, i, to_slave_idx, masters_axi[i].aw_id);
        end else begin
          $display("%0tns > Master %0d: AW to Decerror: Axi ID: %b",
              $time, i, to_slave_idx, masters_axi[i].aw_id);
        end
      end

//      mst_axi_id_t   mst_axi_id;
//      axi_addr_t     mst_axi_addr;
//      axi_pkg::len_t mst_axi_len;
//
//      id_slv_t       exp_slv;
//      slv_axi_id_t   exp_slv_axi_id;
//      slave_exp_ax_t exp_slv_aw;
//      master_exp_t   exp_mst_w;
//      master_exp_t   exp_mst_b;
//
//      // for r response injection on atop
//      master_exp_t   exp_mst_r;
//
//      logic          exp_decerr;
//
//      if (masters_axi[i].aw_valid && masters_axi[i].aw_ready) begin
//        exp_decerr     = 1'b1;
//        mst_axi_id     = masters_axi[i].aw_id;
//        mst_axi_addr   = masters_axi[i].aw_addr;
//        mst_axi_len    = masters_axi[i].aw_len;
//        exp_slv_axi_id = {id_mst_t'(i), mst_axi_id};
//        exp_slv        = '0;
//        for (int unsigned j = 0; j < NoAddrRules; j++) begin
//          if ((mst_axi_addr >= AddrMap[j].start_addr) && (mst_axi_addr < AddrMap[j].end_addr)) begin
//            exp_slv = AddrMap[j].mst_port_idx;
//            exp_decerr = 1'b0;
//          end
//        end
//        // push the required w beats into the right fifo
//        for (int unsigned j = 0; j <= mst_axi_len; j++) begin
//          exp_mst_w = (j == mst_axi_len) ? '{mst_axi_id: mst_axi_id, last: 1'b1} : '{mst_axi_id: mst_axi_id, last: 1'b0};
//          this.mst_exp_w_fifo[i].push_back(exp_mst_w);
//        end
//        if (exp_decerr) begin
//          $display("%0tns > Master %0d: AW to Decerror: Axi ID: %b", $time, i, mst_axi_id);
//          exp_mst_b = '{mst_axi_id: mst_axi_id, last: 1'b1};
//          this.mst_exp_b_queue[i].push(mst_axi_id, exp_mst_b);
//          incr_expected_tests();
//
//        end else begin
//          $display("%0tns > Master %0d: AW to Slave %0d: Axi ID: %b", $time, i, exp_slv, mst_axi_id);
//          // push the expected vectors AW for exp_slv
//          exp_slv_aw = '{slv_axi_id: exp_slv_axi_id, slv_axi_addr: mst_axi_addr, slv_axi_len: mst_axi_len};
//          //$display("Expected Slv Axi Id is: %b", exp_slv_axi_id);
//          this.slv_exp_aw_queue[exp_slv].push(exp_slv_axi_id, exp_slv_aw);
//          incr_expected_tests();
//          incr_expected_tests();
//          incr_expected_tests();
//          incr_expected_tests();
//
//          // w beats get pushed, if aw arrives at slave
//          exp_mst_b = '{mst_axi_id: mst_axi_id, last: 1'b1};
//          this.mst_exp_b_queue[i].push(mst_axi_id, exp_mst_b);
//          incr_expected_tests();
//        end
//        // inject expected r responses on atop
//        if(masters_axi[i].aw_atop[5]) begin
//          // push the required r beats into the right fifo
//          for (int unsigned j = 0; j <= mst_axi_len; j++) begin
//            exp_mst_r = (j == mst_axi_len) ? '{mst_axi_id: mst_axi_id, last: 1'b1} : '{mst_axi_id: mst_axi_id, last: 1'b0};
//            this.mst_exp_r_queue[i].push(mst_axi_id, exp_mst_r);
//            incr_expected_tests();
//          end
//        end
//      end
    endtask : monitor_mst_aw

    task monitor_slv_aw(input int unsigned i);
      exp_ax_t    exp_aw;
      slave_exp_t exp_slv_w;
      if (slaves_axi[i].aw_valid && slaves_axi[i].aw_ready) begin
        // test if the aw beat was expected
        exp_aw = this.exp_aw_queue[i].pop_id(slaves_axi[i].aw_id);
        $display("%0tns > Slave  %0d: AW Axi ID: %b",
            $time, i, slaves_axi[i].aw_id);
        if (exp_aw.slv_axi_id != slaves_axi[i].aw_id) begin
          incr_failed_tests(1);
          $warning("Slave %0d: Unexpected AW with ID: %b", i, slaves_axi[i].aw_id);
        end
        if (exp_aw.slv_axi_addr != slaves_axi[i].aw_addr) begin
          incr_failed_tests(1);
          $warning("Slave %0d: Unexpected AW with ID: %b and ADDR: %h, exp: %h",
              i, slaves_axi[i].aw_id, slaves_axi[i].aw_addr, exp_aw.slv_axi_addr);
        end
        if (exp_aw.slv_axi_len != slaves_axi[i].aw_len) begin
          incr_failed_tests(1);
          $warning("Slave %0d: Unexpected AW with ID: %b and LEN: %h, exp: %h",
              i, slaves_axi[i].aw_id, slaves_axi[i].aw_len, exp_aw.slv_axi_len);
        end
        incr_conducted_tests(3);

        // push the required w beats into the right fifo
        for (int unsigned j = 0; j <= slv_axi_len; j++) begin
          exp_slv_w = (j == slv_axi_len) ?
              '{slv_axi_id: slv_axi_id, last: 1'b1} : '{slv_axi_id: slv_axi_id, last: 1'b0};
          this.slv_exp_w_fifo[i].push_back(exp_slv_w);
          incr_expected_tests(1);
        end
      end
    endtask : monitor_slv_aw

    task monitor_slv_w(input int unsigned i);
      slave_exp_t     exp_slv_w;
      if (slaves_axi[i].w_valid && slaves_axi[i].w_ready) begin
        exp_slv_w = '{last: slaves_axi[i].w_last , default:'0};
        this.slv_act_w_fifo[i].push_back(act_svl_w);
      end
    endtask : monitor_slv_w

    task check_slv_w(input int unsigned i);
      slave_exp_t exp_w, act_w;
      forever begin
        wait(this.slv_exp_w_fifo[i].size() != 0 && this.slv_act_w_fifo[i].size() != 0);
        exp_w = this.slv_exp_w_fifo.pop_front();
        axt_w = this.slv_act_w_fifo.pop_front();
        // do the check
        incr_conducted_tests();
        if(exp_w.last != act_w.last) begin
          incr_failed_tests();
          $warning("Slave %d: unexpected W beat last flag %b.", i, w_last);
        end
      end
    endtask : check_slv_w

//    task automatic monitor_slv_aw(input int unsigned i);
//      slave_exp_ax_t  exp_slv_aw;
//      slv_axi_id_t    slv_axi_id;
//      axi_addr_t      slv_axi_addr;
//      axi_pkg::len_t  slv_axi_len;
//      slave_exp_t     exp_slv_w;
//
//      if (slaves_axi[i].aw_valid && slaves_axi[i].aw_ready) begin
//        axi_pkg::len_t slv_axi_len;
//
//        slv_axi_id   = slaves_axi[i].aw_id;
//        slv_axi_addr = slaves_axi[i].aw_addr;
//        slv_axi_len  = slaves_axi[i].aw_len;
//        incr_conducted_tests();
//        if (this.slv_exp_aw_queue[i].empty()) begin
//          incr_failed_tests();
//          $warning($sformatf("%0tns > Slave: %0d recieved unexpected AW with ID: %b", $time, i, slv_axi_id));
//        end else begin
//          // check that the ids are the same
//          exp_slv_aw = this.slv_exp_aw_queue[i].pop_id(slv_axi_id);
//          $display("%0tns > Slave  %0d: AW Axi ID: %b", $time, i, slv_axi_id);
//
//          incr_conducted_tests();
//          if (exp_slv_aw.slv_axi_id != slv_axi_id) begin
//            incr_failed_tests();
//            $warning("Slave %0d: Unexpected AW with ID: %b", i, slv_axi_id);
//          end
//          incr_conducted_tests();
//          if (exp_slv_aw.slv_axi_addr != slv_axi_addr) begin
//            incr_failed_tests();
//            $warning("Slave %0d: Unexpected AW with ID: %b and ADDR: %h, exp: %h", i, slv_axi_id, slv_axi_addr, exp_slv_aw.slv_axi_addr);
//          end
//          incr_conducted_tests();
//          if (exp_slv_aw.slv_axi_len != slv_axi_len) begin
//            incr_failed_tests();
//            $warning("Slave %0d: Unexpected AW with ID: %b and LEN: %h, exp: %h", i, slv_axi_id, slv_axi_len, exp_slv_aw.slv_axi_len);
//          end
//        end
//        // push the required w beats into the right fifo
//        for (int unsigned j = 0; j <= slv_axi_len; j++) begin
//          exp_slv_w = (j == slv_axi_len) ? '{slv_axi_id: slv_axi_id, last: 1'b1} : '{slv_axi_id: slv_axi_id, last: 1'b0};
//          this.slv_exp_w_fifo[i].push_back(exp_slv_w);
//          incr_expected_tests();
//        end


//      end
//    endtask : monitor_slv_aw

    task automatic monitor_mst_w(input int unsigned i);
      master_exp_t exp_mst_w, buffer_w;
      logic        w_last;
      if (masters_axi[i].w_valid && masters_axi[i].w_ready) begin
        w_last = masters_axi[i].w_last;
        if (this.mst_exp_w_fifo[i].size() == 0) begin
            buffer_w = '{mst_axi_id: '1, last: w_last};
        end else begin
          while (this.mst_w_buffer[i].size() != 0) begin
            buffer_w  = this.mst_w_buffer[i].pop_front();
            exp_mst_w = this.mst_exp_w_fifo[i].pop_front();
            if (buffer_w.last != exp_mst_w.last) begin
              $warning("Master %0d: unexpected W beat last flag. Exp Fifo size: %0d", i, this.mst_exp_w_fifo[i].size());
            end
          end

          exp_mst_w = this.mst_exp_w_fifo[i].pop_front();
          if (w_last != exp_mst_w.last) begin
            $warning("Master %d: unexpected W beat last flag %b. Exp Fifo size: %0d", i, w_last, this.mst_exp_w_fifo[i].size());
          end
        end
      end
    endtask : monitor_mst_w

    task automatic monitor_slv_w(input int unsigned i);
      slave_exp_t exp_slv_w;
      slave_exp_t buffer_w;
      logic       w_last;

      if (slaves_axi[i].w_valid && slaves_axi[i].w_ready) begin
        incr_conducted_tests();
        w_last = slaves_axi[i].w_last;
        if (this.slv_exp_w_fifo[i].size() == 0) begin
          buffer_w = '{slv_axi_id: '1, last: w_last};
          this.slv_w_buffer_fifo[i].push_back(buffer_w);
          // incr_failed_tests();
          //$info("Salve %d: W beat in buffer in.", i);
        end else begin
          // fix, because w's can get sent before AW!
          while (this.slv_w_buffer_fifo[i].size() != 0 && this.slv_exp_w_fifo[i].size() > 1) begin
            buffer_w  = this.slv_w_buffer_fifo[i].pop_front();
            exp_slv_w = this.slv_exp_w_fifo[i].pop_front();
            //$info("Salve %d: W beat in buffer out.", i);
            if (buffer_w.last != exp_slv_w.last) begin
              incr_failed_tests();
              $warning("Slave %d: unexpected W beat last flag %b.", i, w_last);
            end
          end

          exp_slv_w = this.slv_exp_w_fifo[i].pop_front();
          //if(i==3) begin
          //  $info("W Beat on SLV 3: expected: %b, on line last %b", exp_slv_w, w_last);
          //end
          if (w_last != exp_slv_w.last) begin
            incr_failed_tests();
            $warning("Slave %d: unexpected W beat last flag %b.", i, w_last);
          end
        end
      end
    endtask : monitor_slv_w

    task resolve_slv_w(input int unsigned i);

    endtask : resolve_slv_w

    task automatic monitor_mst_b(input int unsigned i);
      master_exp_t exp_mst_b;
      mst_axi_id_t mst_axi_b_id;
      if (masters_axi[i].b_valid && masters_axi[i].b_ready) begin
        incr_conducted_tests();
        mst_axi_b_id = masters_axi[i].b_id;
        if (this.mst_exp_b_queue[i].empty()) begin
          incr_failed_tests();
          $warning("Master %d: unexpected B beat with ID: %b detected!", i, mst_axi_b_id);
        end else begin
          exp_mst_b = this.mst_exp_b_queue[i].pop_id(mst_axi_b_id);
          if (mst_axi_b_id != exp_mst_b.mst_axi_id) begin
            incr_failed_tests();
            $warning("Master: %d got unexpected B with ID: %b", i, mst_axi_b_id);
          end
        end
      end
    endtask : monitor_mst_b

    task automatic monitor_mst_ar(input int unsigned i);
      mst_axi_id_t   mst_axi_id;
      axi_addr_t     mst_axi_addr;
      axi_pkg::len_t mst_axi_len;

      id_slv_t       exp_slv;
      slv_axi_id_t   exp_slv_axi_id;
      slave_exp_ax_t exp_slv_ar;
      master_exp_t   exp_mst_r;

      logic          exp_decerr;

      if (masters_axi[i].ar_valid && masters_axi[i].ar_ready) begin
        exp_decerr     = 1'b1;
        mst_axi_id     = masters_axi[i].ar_id;
        mst_axi_addr   = masters_axi[i].ar_addr;
        mst_axi_len    = masters_axi[i].ar_len;
        exp_slv_axi_id = {id_mst_t'(i), mst_axi_id};
        exp_slv        = '0;
        for (int unsigned j = 0; j < NoAddrRules; j++) begin
          if ((mst_axi_addr >= AddrMap[j].start_addr) && (mst_axi_addr < AddrMap[j].end_addr)) begin
            exp_slv = AddrMap[j].mst_port_idx;
            exp_decerr = 1'b0;
          end
        end
        if (exp_decerr) begin
          $display("%0tns > Master %0d: AR to Decerror: Axi ID: %b", $time, i, mst_axi_id);
        end else begin
          $display("%0tns > Master %0d: AR to Slave %0d: Axi ID: %b", $time, i, exp_slv, mst_axi_id);
          // push the expected vectors AW for exp_slv
          exp_slv_ar = '{slv_axi_id: exp_slv_axi_id, slv_axi_addr: mst_axi_addr, slv_axi_len: mst_axi_len};
          //$display("Expected Slv Axi Id is: %b", exp_slv_axi_id);
          this.slv_exp_ar_queue[exp_slv].push(exp_slv_axi_id, exp_slv_ar);
          incr_expected_tests();
        end
        // push the required r beats into the right fifo
        for (int unsigned j = 0; j <= mst_axi_len; j++) begin
          exp_mst_r = (j == mst_axi_len) ? '{mst_axi_id: mst_axi_id, last: 1'b1} : '{mst_axi_id: mst_axi_id, last: 1'b0};
          this.mst_exp_r_queue[i].push(mst_axi_id, exp_mst_r);
          incr_expected_tests();
        end
      end
    endtask : monitor_mst_ar

    task automatic monitor_slv_ar(input int unsigned i);
      slave_exp_ax_t exp_slv_ar;
      slv_axi_id_t   slv_axi_id;
      if (slaves_axi[i].ar_valid && slaves_axi[i].ar_ready) begin
        incr_conducted_tests();
        slv_axi_id = slaves_axi[i].ar_id;
        if (this.slv_exp_ar_queue[i].empty()) begin
          incr_failed_tests();
        end else begin
          // check that the ids are the same
          exp_slv_ar = this.slv_exp_ar_queue[i].pop_id(slv_axi_id);
          $display("%0tns > Slave  %0d: AR Axi ID: %b", $time, i, slv_axi_id);
          if (exp_slv_ar.slv_axi_id != slv_axi_id) begin
            incr_failed_tests();
            $warning("Slave  %d: Unexpected AR with ID: %b", i, slv_axi_id);
          end
        end
      end
    endtask : monitor_slv_ar

    task automatic monitor_mst_r(input int unsigned i);
      master_exp_t exp_mst_r;
      mst_axi_id_t mst_axi_r_id;
      logic        mst_axi_r_last;
      if (masters_axi[i].r_valid && masters_axi[i].r_ready) begin
        incr_conducted_tests();
        mst_axi_r_id   = masters_axi[i].r_id;
        mst_axi_r_last = masters_axi[i].r_last;
        if (this.mst_exp_r_queue[i].empty()) begin
          incr_failed_tests();
          $warning("Master %d: unexpected R beat with ID: %b detected!", i, mst_axi_r_id);
        end else begin
          exp_mst_r = this.mst_exp_r_queue[i].pop_id(mst_axi_r_id);
          if (mst_axi_r_id != exp_mst_r.mst_axi_id) begin
            incr_failed_tests();
            $warning("Master: %d got unexpected R with ID: %b", i, mst_axi_r_id);
          end
          if (mst_axi_r_last != exp_mst_r.last) begin
            incr_failed_tests();
            $warning("Master: %d got unexpected R with ID: %b and last flag: %b", i, mst_axi_r_id, mst_axi_r_last);
          end
        end
      end
    endtask : monitor_mst_r

    task incr_expected_tests(input int unsigned times);
      cnt_sem.get();
      this.tests_expected += times;
      cnt_sem.put();
    endtask : incr_expected_tests

    task incr_conducted_tests(input int unsigned times);
      cnt_sem.get();
      this.tests_conducted += times;
      cnt_sem.put();
    endtask : incr_conducted_tests

    task incr_failed_tests(input int unsigned times);
      cnt_sem.get();
      this.tests_failed += times;
      cnt_sem.put();
    endtask : incr_failed_tests


    task run();
      do begin
        // at every cycle span some monitoring processes
        cycle_start();
        // execute all processes that put something into the queues
        PushMon: fork
          proc_mst_aw: begin
            for (int unsigned i = 0; i < NoMasters; i++) begin
              monitor_mst_aw(i);
            end
          end
          proc_mst_ar: begin
            for (int unsigned i = 0; i < NoMasters; i++) begin
              monitor_mst_ar(i);
            end
          end
        join : PushMon
        // this one pops and pushes something
        proc_slv_aw: begin
          for (int unsigned i = 0; i < NoSlaves; i++) begin
            monitor_slv_aw(i);
          end
        end
        proc_mst_w: begin
          for (int unsigned i = 0; i < NoMasters; i++) begin
            monitor_mst_w(i);
          end
        end
        proc_slv_w: begin
          for (int unsigned i = 0; i < NoSlaves; i++) begin
            monitor_slv_w(i);
          end
        end
        // execute all processes that pop something from the queues
        PopMon: fork
          proc_mst_b: begin
            for (int unsigned i = 0; i < NoMasters; i++) begin
              monitor_mst_b(i);
            end
          end
          proc_slv_ar: begin
            for (int unsigned i = 0; i < NoSlaves; i++) begin
              monitor_slv_ar(i);
            end
          end
          proc_mst_r: begin
            for (int unsigned i = 0; i < NoMasters; i++) begin
              monitor_mst_r(i);
            end
          end
        join : PopMon
        cycle_end();
      end while (1'b1);
    endtask : run

    task print_result();
      $info("Simulation has ended!");
      $display("Tests Expected:  %d", this.tests_expected);
      $display("Tests Conducted: %d", this.tests_conducted);
      $display("Tests Failed:    %d", this.tests_failed);
      if(tests_failed > 0) begin
        $error("Simulation encountered unexpected Transactions!!!!!!");
      end
    endtask : print_result

  endclass : axi_xbar_monitor

endpackage
