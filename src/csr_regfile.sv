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
// Author: Florian Zaruba, ETH Zurich
// Date: 05.05.2017
// Description: CSR Register File as specified by RISC-V

import ariane_pkg::*;

module csr_regfile #(
    parameter int          ASID_WIDTH      = 1,
    parameter int unsigned NR_COMMIT_PORTS = 2
)(
    input  logic                  clk_i,                      // Clock
    input  logic                  rst_ni,                     // Asynchronous reset active low
    input  logic [63:0]           time_i,                     // Platform Timer
    input  logic                  time_irq_i,                 // Timer threw a interrupt

    // send a flush request out if a CSR with a side effect has changed (e.g. written)
    output logic                       flush_o,
    output logic                       halt_csr_o,            // halt requested
    // Debug CSR Port
    input  logic                       debug_csr_req_i,       // Request from debug to read the CSR regfile
    input  logic [11:0]                debug_csr_addr_i,      // Address of CSR
    input  logic                       debug_csr_we_i,        // Is it a read or write?
    input  logic [63:0]                debug_csr_wdata_i,     // Data to write
    output logic [63:0]                debug_csr_rdata_o,     // Read data
    // commit acknowledge
    input  logic [NR_COMMIT_PORTS-1:0] commit_ack_i,          // Commit acknowledged a instruction -> increase instret CSR
    // Core and Cluster ID
    input  logic  [3:0]           core_id_i,                  // Core ID is considered static
    input  logic  [5:0]           cluster_id_i,               // Cluster ID is considered static
    input  logic  [63:0]          boot_addr_i,                // Address from which to start booting, mtvec is set to the same address
    // we are taking an exception
    input exception_t             ex_i,                       // We've got an exception from the commit stage, take its

    input  fu_op                  csr_op_i,                   // Operation to perform on the CSR file
    input  logic  [11:0]          csr_addr_i,                 // Address of the register to read/write
    input  logic  [63:0]          csr_wdata_i,                // Write data in
    output logic  [63:0]          csr_rdata_o,                // Read data out
    input  logic  [63:0]          pc_i,                       // PC of instruction accessing the CSR
    output exception_t            csr_exception_o,            // attempts to access a CSR without appropriate privilege
                                                              // level or to write  a read-only register also
                                                              // raises illegal instruction exceptions.
    // Interrupts/Exceptions
    output logic  [63:0]          epc_o,                      // Output the exception PC to PC Gen, the correct CSR (mepc, sepc) is set accordingly
    output logic                  eret_o,                     // Return from exception, set the PC of epc_o
    output logic  [63:0]          trap_vector_base_o,         // Output base of exception vector, correct CSR is output (mtvec, stvec)
    output priv_lvl_t             priv_lvl_o,                 // Current privilege level the CPU is in
    // FPU
    output logic [4:0]            fflags_o,                   // Floating-Point Accured Exceptions
    output logic [2:0]            frm_o,                      // Floating-Point Dynamic Rounding Mode
    // MMU
    output logic                  en_translation_o,           // enable VA translation
    output logic                  en_ld_st_translation_o,     // enable VA translation for load and stores
    output priv_lvl_t             ld_st_priv_lvl_o,           // Privilege level at which load and stores should happen
    output logic                  sum_o,
    output logic                  mxr_o,
    output logic [43:0]           satp_ppn_o,
    output logic [ASID_WIDTH-1:0] asid_o,
    // external interrupts
    input  logic [1:0]            irq_i,                      // external interrupt in
    input  logic                  ipi_i,                      // inter processor interrupt -> connected to machine mode sw
    // Visualization Support
    output logic                  tvm_o,                      // trap virtual memory
    output logic                  tw_o,                       // timeout wait
    output logic                  tsr_o,                      // trap sret
    // Caches
    output logic                  icache_en_o,                // L1 ICache Enable
    output logic                  dcache_en_o,                // L1 DCache Enable
    // Performance Counter
    output logic  [11:0]          perf_addr_o,                // address to performance counter module
    output logic  [63:0]          perf_data_o,                // write data to performance counter module
    input  logic  [63:0]          perf_data_i,                // read data from performance counter module
    output logic                  perf_we_o
);
    // internal signal to keep track of access exceptions
    logic        read_access_exception, update_access_exception;
    logic        csr_we, csr_read;
    logic [63:0] csr_wdata, csr_rdata;
    priv_lvl_t   trap_to_priv_lvl;
    // register for enabling load store address translation, this is critical, hence the register
    logic        en_ld_st_translation_d, en_ld_st_translation_q;

    logic  mret;  // return from M-mode exception
    logic  sret;  // return from S-mode exception

    csr_t  csr_addr;
    // ----------------
    // Assignments
    // ----------------
    // Debug MUX
    assign csr_addr = csr_t'(((debug_csr_req_i) ? debug_csr_addr_i : csr_addr_i));
    // Output the read data directly
    assign debug_csr_rdata_o = csr_rdata;

    // ----------------
    // CSR Registers
    // ----------------
    // privilege level register
    priv_lvl_t   priv_lvl_d, priv_lvl_q;

    typedef struct packed {
        logic         sd;     // signal dirty - read-only - hardwired zero
        logic [62:36] wpri4;  // writes preserved reads ignored
        logic [1:0]   sxl;    // variable supervisor mode xlen - hardwired to zero
        logic [1:0]   uxl;    // variable user mode xlen - hardwired to zero
        logic [8:0]   wpri3;  // writes preserved reads ignored
        logic         tsr;    // trap sret
        logic         tw;     // time wait
        logic         tvm;    // trap virtual memory
        logic         mxr;    // make executable readable
        logic         sum;    // permit supervisor user memory access
        logic         mprv;   // modify privilege - privilege level for ld/st
        logic [1:0]   xs;     // extension register - hardwired to zero
        logic [1:0]   fs;     // extension register - hardwired to zero
        priv_lvl_t    mpp;    // holds the previous privilege mode up to machine
        logic [1:0]   wpri2;  // writes preserved reads ignored
        logic         spp;    // holds the previous privilege mode up to supervisor
        logic         mpie;   // machine interrupts enable bit active prior to trap
        logic         wpri1;  // writes preserved reads ignored
        logic         spie;   // supervisor interrupts enable bit active prior to trap
        logic         upie;   // user interrupts enable bit active prior to trap - hardwired to zero
        logic         mie;    // machine interrupts enable
        logic         wpri0;  // writes preserved reads ignored
        logic         sie;    // supervisor interrupts enable
        logic         uie;    // user interrupts enable - hardwired to zero
    } status_t;

    status_t mstatus_q, mstatus_d;

    logic [63:0] mtvec_q,    mtvec_d;
    logic [63:0] medeleg_q,  medeleg_d;
    logic [63:0] mideleg_q,  mideleg_d;
    logic [63:0] mip_q,      mip_d;
    logic [63:0] mie_q,      mie_d;
    logic [63:0] mscratch_q, mscratch_d;
    logic [63:0] mepc_q,     mepc_d;
    logic [63:0] mcause_q,   mcause_d;
    logic [63:0] mtval_q,    mtval_d;

    logic [63:0] stvec_q,    stvec_d;
    logic [63:0] sscratch_q, sscratch_d;
    logic [63:0] sepc_q,     sepc_d;
    logic [63:0] scause_q,   scause_d;
    logic [63:0] stval_q,    stval_d;
    logic [63:0] dcache_q,   dcache_d;
    logic [63:0] icache_q,   icache_d;

    logic        wfi_d,      wfi_q;

    logic [63:0] cycle_q,    cycle_d;
    logic [63:0] instret_q,  instret_d;

    typedef struct packed {
        logic [3:0]  mode;
        logic [15:0] asid;
        logic [43:0] ppn;
    } satp_t;

    satp_t satp_q, satp_d;

    // Floating-Point control and status register (32-bit!)
    typedef struct packed {
        logic [31:8] reserved;  // reserved for L extension, return 0 otherwise
        logic [2:0]  frm;       // float rounding mode
        logic [4:0]  fflags;    // float exception flags
    } fcsr_t;

    fcsr_t fcsr_q, fcsr_d;

    // ----------------
    // CSR Read logic
    // ----------------
    always_comb begin : csr_read_process
        // a read access exception can only occur if we attempt to read a CSR which does not exist
        read_access_exception = 1'b0;
        csr_rdata = 64'b0;
        // feed through address of performance counter
        perf_addr_o = csr_addr.address;

        if (csr_read) begin
            case (csr_addr.address)

                // Floating-Point
                CSR_FFLAGS:             csr_rdata = {59'b0, fcsr_q.fflags};
                CSR_FRM:                csr_rdata = {61'b0, fcsr_q.frm};
                CSR_FCSR:               csr_rdata = {32'b0, fcsr_q};

                CSR_SSTATUS:            csr_rdata = mstatus_q & 64'h3fffe1fee;
                CSR_SIE:                csr_rdata = mie_q & mideleg_q;
                CSR_SIP:                csr_rdata = mip_q & mideleg_q;
                CSR_STVEC:              csr_rdata = stvec_q;
                CSR_SCOUNTEREN:         csr_rdata = 64'b0; // not implemented
                CSR_SSCRATCH:           csr_rdata = sscratch_q;
                CSR_SEPC:               csr_rdata = sepc_q;
                CSR_SCAUSE:             csr_rdata = scause_q;
                CSR_STVAL:              csr_rdata = stval_q;
                CSR_SATP: begin
                    // intercept reads to SATP if in S-Mode and TVM is enabled
                    if (priv_lvl_q == PRIV_LVL_S && mstatus_q.tvm)
                        read_access_exception = 1'b1;
                    else
                        csr_rdata = satp_q;
                end

                CSR_MSTATUS:            csr_rdata = mstatus_q;
                CSR_MISA:               csr_rdata = ISA_CODE;
                CSR_MEDELEG:            csr_rdata = medeleg_q;
                CSR_MIDELEG:            csr_rdata = mideleg_q;
                CSR_MIP:                csr_rdata = mip_q;
                CSR_MIE:                csr_rdata = mie_q;
                CSR_MTVEC:              csr_rdata = mtvec_q;
                CSR_MCOUNTEREN:         csr_rdata = 64'b0; // not implemented
                CSR_MSCRATCH:           csr_rdata = mscratch_q;
                CSR_MEPC:               csr_rdata = mepc_q;
                CSR_MCAUSE:             csr_rdata = mcause_q;
                CSR_MTVAL:              csr_rdata = mtval_q;
                CSR_MVENDORID:          csr_rdata = 64'b0; // not implemented
                CSR_MARCHID:            csr_rdata = 64'b0; // PULP, anonymous source (no allocated ID yet)
                CSR_MIMPID:             csr_rdata = 64'b0; // not implemented
                CSR_MHARTID:            csr_rdata = {53'b0, cluster_id_i[5:0], 1'b0, core_id_i[3:0]};
                CSR_MCYCLE:             csr_rdata = cycle_q;
                CSR_MINSTRET:           csr_rdata = instret_q;
                CSR_DCACHE:             csr_rdata = dcache_q;
                CSR_ICACHE:             csr_rdata = icache_q;
                // Counters and Timers
                CSR_CYCLE:              csr_rdata = cycle_q;
                CSR_TIME:               csr_rdata = time_i;
                CSR_INSTRET:            csr_rdata = instret_q;
                CSR_L1_ICACHE_MISS,
                CSR_L1_DCACHE_MISS,
                CSR_ITLB_MISS,
                CSR_DTLB_MISS,
                CSR_LOAD,
                CSR_STORE,
                CSR_EXCEPTION,
                CSR_EXCEPTION_RET,
                CSR_BRANCH_JUMP,
                CSR_CALL,
                CSR_RET,
                CSR_MIS_PREDICT:        csr_rdata = perf_data_i;
                default: read_access_exception = 1'b1;
            endcase
        end
    end
    // ---------------------------
    // CSR Write and update logic
    // ---------------------------
    always_comb begin : csr_update
        automatic satp_t sapt;
        automatic logic [63:0] mip;
        automatic logic [63:0] instret;

        sapt = satp_q;
        mip = csr_wdata & 64'h33;
        instret = instret_q;
        // only FCSR, USIP, SSIP, UTIP, STIP are write-able

        eret_o                  = 1'b0;
        flush_o                 = 1'b0;
        update_access_exception = 1'b0;

        perf_we_o               = 1'b0;
        perf_data_o             = 'b0;

        fcsr_d                  = fcsr_q;

        priv_lvl_d              = priv_lvl_q;
        mstatus_d               = mstatus_q;
        mtvec_d                 = mtvec_q;
        medeleg_d               = medeleg_q;
        mideleg_d               = mideleg_q;
        mip_d                   = mip_q;
        mie_d                   = mie_q;
        mepc_d                  = mepc_q;
        mcause_d                = mcause_q;
        mscratch_d              = mscratch_q;
        mtval_d                 = mtval_q;
        dcache_d                = dcache_q;
        icache_d                = icache_q;

        sepc_d                  = sepc_q;
        scause_d                = scause_q;
        stvec_d                 = stvec_q;
        sscratch_d              = sscratch_q;
        stval_d                 = stval_q;
        satp_d                  = satp_q;
        en_ld_st_translation_d  = en_ld_st_translation_q;

        // check for correct access rights and that we are writing
        if (csr_we) begin
            case (csr_addr.address)

                // Floating-Point
                CSR_FFLAGS: begin
                    fcsr_d.fflags = csr_wdata[4:0];
                    // this instruction has side-effects
                    flush_o = 1'b1;
                end
                CSR_FRM: begin
                    fcsr_d.frm    = csr_wdata[2:0];
                    // this instruction has side-effects
                    flush_o = 1'b1;
                end
                CSR_FCSR: begin
                    fcsr_d[7:0]   = csr_wdata[7:0]; // ignore writes to reserved space
                    // this instruction has side-effects
                    flush_o = 1'b1;
                end

                // sstatus is a subset of mstatus - mask it accordingly
                CSR_SSTATUS: begin
                    mstatus_d   = csr_wdata & 64'h3fffe1fee;
                    // this instruction has side-effects
                    flush_o = 1'b1;
                end
                // even machine mode interrupts can be visible and set-able to supervisor
                // if the corresponding bit in mideleg is set
                CSR_SIE: begin
                    // the mideleg makes sure only delegate-able register (and therefore also only implemented registers)
                    // are written
                    for (int unsigned i = 0; i < 64; i++)
                        if (mideleg_q[i])
                            mie_d[i] = csr_wdata[i];
                end

                CSR_SIP: begin
                    for (int unsigned i = 0; i < 64; i++)
                        if (mideleg_q[i])
                            mip_d[i] = mip[i];
                end

                CSR_SCOUNTEREN:;
                CSR_STVEC:              stvec_d     = {csr_wdata[63:2], 1'b0, csr_wdata[0]};
                CSR_SSCRATCH:           sscratch_d  = csr_wdata;
                CSR_SEPC:               sepc_d      = {csr_wdata[63:1], 1'b0};
                CSR_SCAUSE:             scause_d    = csr_wdata;
                CSR_STVAL:              stval_d     = csr_wdata;
                // supervisor address translation and protection
                CSR_SATP: begin
                    // intercept SATP writes if in S-Mode and TVM is enabled
                    if (priv_lvl_q == PRIV_LVL_S && mstatus_q.tvm)
                        update_access_exception = 1'b1;
                    else begin
                        sapt      = satp_t'(csr_wdata);
                        // only make ASID_LEN - 1 bit stick, that way software can figure out how many ASID bits are supported
                        sapt.asid = sapt.asid & {{(16-ASID_WIDTH){1'b0}}, {ASID_WIDTH{1'b1}}};
                        satp_d    = sapt;
                    end
                    // changing the mode can have side-effects on address translation (e.g.: other instructions), re-fetch
                    // the next instruction by executing a flush
                    flush_o = 1'b1;
                end

                CSR_MSTATUS: begin
                    mstatus_d      = csr_wdata;
                    mstatus_d.sxl  = 2'b10;
                    mstatus_d.uxl  = 2'b10;
                    // hardwired zero registers
                    mstatus_d.sd   = 1'b0;
                    mstatus_d.xs   = 2'b0;
                    mstatus_d.fs   = 2'b0;
                    mstatus_d.upie = 1'b0;
                    mstatus_d.uie  = 1'b0;
                    // this register has side-effects on other registers, flush the pipeline
                    flush_o        = 1'b1;
                end
                // MISA is WARL (Write Any Value, Reads Legal Value)
                CSR_MISA:;
                // machine exception delegation register
                // 0 - 15 exceptions supported
                CSR_MEDELEG:            medeleg_d   = csr_wdata & 64'hF7FF;
                // machine interrupt delegation register
                // we do not support user interrupt delegation
                CSR_MIDELEG:            mideleg_d   = csr_wdata & 64'hBBB;

                // mask the register so that unsupported interrupts can never be set
                CSR_MIE:                mie_d       = csr_wdata & 64'hBBB; // we only support supervisor and m-mode interrupts
                CSR_MIP:                mip_d       = mip;

                CSR_MTVEC: begin
                    mtvec_d     = {csr_wdata[63:2], 1'b0, csr_wdata[0]};
                    // we are in vector mode, this implementation requires the additional
                    // alignment constraint of 64 * 4 bytes
                    if (csr_wdata[0])
                        mtvec_d = {csr_wdata[63:8], 7'b0, csr_wdata[0]};
                end
                CSR_MCOUNTEREN:;

                CSR_MSCRATCH:           mscratch_d  = csr_wdata;
                CSR_MEPC:               mepc_d      = {csr_wdata[63:1], 1'b0};
                CSR_MCAUSE:             mcause_d    = csr_wdata;
                CSR_MTVAL:              mtval_d     = csr_wdata;
                CSR_MCYCLE:             cycle_d     = csr_wdata;
                CSR_MINSTRET:           instret     = csr_wdata;
                CSR_DCACHE:             dcache_d    = csr_wdata[0]; // enable bit
                CSR_ICACHE:             icache_d    = csr_wdata[0]; // enable bit
                CSR_L1_ICACHE_MISS,
                CSR_L1_DCACHE_MISS,
                CSR_ITLB_MISS,
                CSR_DTLB_MISS,
                CSR_LOAD,
                CSR_STORE,
                CSR_EXCEPTION,
                CSR_EXCEPTION_RET,
                CSR_BRANCH_JUMP,
                CSR_CALL,
                CSR_RET,
                CSR_MIS_PREDICT: begin
                                        perf_data_o = csr_wdata;
                                        perf_we_o   = 1'b1;
                end
                default: update_access_exception = 1'b1;
            endcase
        end
        // ---------------------
        // External Interrupts
        // ---------------------
        // Machine Mode External Interrupt Pending
        mip_d[11] = mie_q[11] & irq_i[1];
        mip_d[9] = mie_q[9] & irq_i[0];
        // Machine software interrupt
        mip_d[3] = mie_q[3] & ipi_i;
        // Timer interrupt pending, coming from platform timer
        mip_d[7] = time_irq_i;

        // -----------------------
        // Manage Exception Stack
        // -----------------------
        // update exception CSRs
        // we got an exception update cause, pc and stval register
        trap_to_priv_lvl = PRIV_LVL_M;
        // Exception is taken
        if (ex_i.valid) begin
            // do not flush, flush is reserved for CSR writes with side effects
            flush_o   = 1'b0;
            // figure out where to trap to
            // a m-mode trap might be delegated if we are taking it in S mode
            // first figure out if this was an exception or an interrupt e.g.: look at bit 63
            // the cause register can only be 6 bits long (as we only support 64 exceptions)
            if ((ex_i.cause[63] && mideleg_q[ex_i.cause[5:0]]) ||
                (~ex_i.cause[63] && medeleg_q[ex_i.cause[5:0]])) begin
                // traps never transition from a more-privileged mode to a less privileged mode
                // so if we are already in M mode, stay there
                trap_to_priv_lvl = (priv_lvl_q == PRIV_LVL_M) ? PRIV_LVL_M : PRIV_LVL_S;
            end

            // trap to supervisor mode
            if (trap_to_priv_lvl == PRIV_LVL_S) begin
                // update sstatus
                mstatus_d.sie  = 1'b0;
                mstatus_d.spie = mstatus_q.sie;
                // this can either be user or supervisor mode
                mstatus_d.spp  = logic'(priv_lvl_q);
                // set cause
                scause_d       = ex_i.cause;
                // set epc
                sepc_d         = pc_i;
                // set mtval or stval
                stval_d        = ex_i.tval;
            // trap to machine mode
            end else begin
                // update mstatus
                mstatus_d.mie  = 1'b0;
                mstatus_d.mpie = mstatus_q.mie;
                // save the previous privilege mode
                mstatus_d.mpp  = priv_lvl_q;
                mcause_d       = ex_i.cause;
                // set epc
                mepc_d         = pc_i;
                // set mtval or stval
                mtval_d        = ex_i.tval;
            end

            priv_lvl_d = trap_to_priv_lvl;
        end
        // ------------------------------
        // MPRV - Modify Privilege Level
        // ------------------------------
        // Set the address translation at which the load and stores should occur
        // we can use the previous values since changing the address translation will always involve a pipeline flush
        if (mstatus_q.mprv && satp_q.mode == 4'h8 && (mstatus_q.mpp != PRIV_LVL_M))
            en_ld_st_translation_d = 1'b1;
        else // otherwise we go with the regular settings
            en_ld_st_translation_d = en_translation_o;

        ld_st_priv_lvl_o = (mstatus_q.mprv) ? mstatus_q.mpp : priv_lvl_o;
        en_ld_st_translation_o = en_ld_st_translation_q;
        // ------------------------------
        // Return from Environment
        // ------------------------------
        // When executing an xRET instruction, supposing xPP holds the value y, xIE is set to xPIE; the privilege
        // mode is changed to y; xPIE is set to 1; and xPP is set to U
        if (mret) begin
            // return from exception, IF doesn't care from where we are returning
            eret_o = 1'b1;
            // return to the previous privilege level and restore all enable flags
            // get the previous machine interrupt enable flag
            mstatus_d.mie  = mstatus_q.mpie;
            // restore the previous privilege level
            priv_lvl_d     = mstatus_q.mpp;
            // set mpp to user mode
            mstatus_d.mpp  = PRIV_LVL_U;
            // set mpie to 1
            mstatus_d.mpie = 1'b1;
        end

        if (sret) begin
            // return from exception, IF doesn't care from where we are returning
            eret_o = 1'b1;
            // return the previous supervisor interrupt enable flag
            mstatus_d.sie  = mstatus_d.spie;
            // restore the previous privilege level
            priv_lvl_d     = priv_lvl_t'({1'b0, mstatus_d.spp});
            // set spp to user mode
            mstatus_d.spp  = logic'(PRIV_LVL_U);
            // set spie to 1
            mstatus_d.spie = 1'b1;
        end

        // --------------------
        // Counters
        // --------------------
        // just increment the cycle count
        cycle_d = cycle_q + 1'b1;
        // increase instruction retired counter
        for (int i = 0; i < NR_COMMIT_PORTS; i++) begin
            if (commit_ack_i[i]) begin
                instret++;
            end
        end
        instret_d = instret;
    end

    // ---------------------------
    // CSR OP Select Logic
    // ---------------------------
    always_comb begin : csr_op_logic
        csr_wdata = csr_wdata_i;
        csr_we    = 1'b1;
        csr_read  = 1'b1;
        mret      = 1'b0;
        sret      = 1'b0;

        unique case (csr_op_i)
            CSR_WRITE: csr_wdata = csr_wdata_i;
            CSR_SET:   csr_wdata = csr_wdata_i | csr_rdata;
            CSR_CLEAR: csr_wdata = (~csr_wdata_i) & csr_rdata;
            CSR_READ:  csr_we    = 1'b0;
            SRET: begin
                // the return should not have any write or read side-effects
                csr_we   = 1'b0;
                csr_read = 1'b0;
                sret     = 1'b1; // signal a return from supervisor mode
            end
            MRET: begin
                // the return should not have any write or read side-effects
                csr_we   = 1'b0;
                csr_read = 1'b0;
                mret     = 1'b1; // signal a return from machine mode
            end
            default: begin
                csr_we   = 1'b0;
                csr_read = 1'b0;
            end
        endcase
        // if we are retiring an exception do not return from exception
        if (ex_i.valid) begin
            mret = 1'b0;
            sret = 1'b0;
        end
        // ------------------------------
        // Debug Multiplexer (Priority)
        // ------------------------------
        if (debug_csr_req_i) begin
            // Use the data supplied by the debug unit
            csr_wdata = debug_csr_wdata_i;
            csr_we    = debug_csr_we_i;
            csr_read  = ~debug_csr_we_i;
        end

    end

    logic interrupt_global_enable;
    // --------------------------------------
    // Exception Control & Interrupt Control
    // --------------------------------------
    always_comb begin : exception_ctrl
        automatic logic [63:0] interrupt_cause;
        interrupt_cause = '0;
        // wait for interrupt register
        wfi_d = wfi_q;

        csr_exception_o = {
            64'b0, 64'b0, 1'b0
        };
        // -----------------
        // Interrupt Control
        // -----------------
        // we decode an interrupt the same as an exception, hence it will be taken if the instruction did not
        // throw any previous exception.
        // we have three interrupt sources: external interrupts, software interrupts, timer interrupts (order of precedence)
        // for two privilege levels: Supervisor and Machine Mode
        // Supervisor Timer Interrupt
        if (mie_q[S_TIMER_INTERRUPT[5:0]] && mip_q[S_TIMER_INTERRUPT[5:0]])
            interrupt_cause = S_TIMER_INTERRUPT;
        // Supervisor Software Interrupt
        if (mie_q[S_SW_INTERRUPT[5:0]] && mip_q[S_SW_INTERRUPT[5:0]])
            interrupt_cause = S_SW_INTERRUPT;
        // Supervisor External Interrupt
        if (mie_q[S_EXT_INTERRUPT[5:0]] && mip_q[S_EXT_INTERRUPT[5:0]])
            interrupt_cause = S_EXT_INTERRUPT;
        // Machine Timer Interrupt
        if (mip_q[M_TIMER_INTERRUPT[5:0]] && mie_q[M_TIMER_INTERRUPT[5:0]])
            interrupt_cause = M_TIMER_INTERRUPT;
        // Machine Mode Software Interrupt
        if (mip_q[M_SW_INTERRUPT[5:0]] && mie_q[M_SW_INTERRUPT[5:0]])
            interrupt_cause = M_SW_INTERRUPT;
        // Machine Mode External Interrupt
        if (mip_q[M_EXT_INTERRUPT[5:0]] && mie_q[M_EXT_INTERRUPT[5:0]])
            interrupt_cause = M_EXT_INTERRUPT;

        // An interrupt i will be taken if bit i is set in both mip and mie, and if interrupts are globally enabled.
        // By default, M-mode interrupts are globally enabled if the hart’s current privilege mode  is less
        // than M, or if the current privilege mode is M and the MIE bit in the mstatus register is set.
        interrupt_global_enable = (mstatus_q.mie && (priv_lvl_q == PRIV_LVL_M)) || (priv_lvl_q inside {PRIV_LVL_S, PRIV_LVL_U});
        if (interrupt_cause[63] && interrupt_global_enable) begin
            // we can set the cause here
            csr_exception_o.cause = interrupt_cause;
            // However, if bit i in mideleg is set, interrupts are considered to be globally enabled if the hart’s current privilege
            // mode equals the delegated privilege mode (S or U) and that mode’s interrupt enable bit
            // (SIE or UIE in mstatus) is set, or if the current privilege mode is less than the delegated privilege mode.
            if (mideleg_q[interrupt_cause[5:0]]) begin
                if ((mstatus_q.sie && priv_lvl_q == PRIV_LVL_S) || priv_lvl_q == PRIV_LVL_U)
                    csr_exception_o.valid = 1'b1;
            end else begin
                csr_exception_o.valid = 1'b1;
            end
        end

        // -----------------
        // Privilege Check
        // -----------------
        // only if this is not a CSR request from debug (debug has M privilege status)
        if (!debug_csr_req_i) begin
            // if we are reading or writing, check for the correct privilege level
            if (csr_we || csr_read) begin
                if ((priv_lvl_t'(priv_lvl_q & csr_addr.csr_decode.priv_lvl) != csr_addr.csr_decode.priv_lvl)) begin
                    csr_exception_o.cause = ILLEGAL_INSTR;
                    csr_exception_o.valid = 1'b1;
                end
            end
            // we got an exception in one of the processes above
            // throw an illegal instruction exception
            if (update_access_exception || read_access_exception) begin
                csr_exception_o.cause = ILLEGAL_INSTR;
                // we don't set the tval field as this will be set by the commit stage
                // this spares the extra wiring from commit to CSR and back to commit
                csr_exception_o.valid = 1'b1;
            end
        end

        // -------------------
        // Wait for Interrupt
        // -------------------
        // if there is any interrupt pending un-stall the core
        if (|mip_q) begin
            wfi_d = 1'b0;
        // or alternatively if there is no exception pending, wait here for the interrupt
        end else if (csr_op_i == WFI && !ex_i.valid) begin
            wfi_d = 1'b1;
        end
    end

    // -------------------
    // Output Assignments
    // -------------------
    assign csr_rdata_o      = csr_rdata;
    assign priv_lvl_o       = priv_lvl_q;
    // FPU outputs
    assign fflags_o         = fcsr_q.fflags;
    assign frm_o            = fcsr_q.frm;
    // MMU outputs
    assign satp_ppn_o       = satp_q.ppn;
    assign asid_o           = satp_q.asid[ASID_WIDTH-1:0];
    assign sum_o            = mstatus_q.sum;
    // we support bare memory addressing and SV39
    assign en_translation_o = (satp_q.mode == 4'h8 && priv_lvl_q != PRIV_LVL_M) ? 1'b1 : 1'b0;
    assign mxr_o            = mstatus_q.mxr;
    assign tvm_o            = mstatus_q.tvm;
    assign tw_o             = mstatus_q.tw;
    assign tsr_o            = mstatus_q.tsr;
    assign halt_csr_o       = wfi_q;
    assign icache_en_o      = icache_q[0];
    assign dcache_en_o      = dcache_q[0];

    // output assignments dependent on privilege mode
    always_comb begin : priv_output
        trap_vector_base_o = {mtvec_q[63:2], 2'b0};
        // output user mode stvec
        if (trap_to_priv_lvl == PRIV_LVL_S) begin
            trap_vector_base_o = {stvec_q[63:2], 2'b0};
        end

        // check if we are in vectored mode, if yes then do BASE + 4 * cause
        // we are imposing an additional alignment-constraint of 64 * 4 bytes since
        // we want to spare the costly addition
        if ((mtvec_q[0] || stvec_q[0]) && csr_exception_o.cause[63]) begin
            trap_vector_base_o[7:2] = csr_exception_o.cause[5:0];
        end

        epc_o = mepc_q;
        // we are returning from supervisor mode, so take the sepc register
        if (sret) begin
            epc_o = sepc_q;
        end
    end

    // sequential process
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            priv_lvl_q             <= PRIV_LVL_M;
            // floating-point registers
            fcsr_q                 <= 64'b0;
            // machine mode registers
            mstatus_q              <= 64'b0;
            mtvec_q                <= {boot_addr_i[63:2], 2'b0}; // set to boot address + direct mode
            medeleg_q              <= 64'b0;
            mideleg_q              <= 64'b0;
            mip_q                  <= 64'b0;
            mie_q                  <= 64'b0;
            mepc_q                 <= 64'b0;
            mcause_q               <= 64'b0;
            mscratch_q             <= 64'b0;
            mtval_q                <= 64'b0;
            dcache_q               <= 64'b1;
            icache_q               <= 64'b1;
            // supervisor mode registers
            sepc_q                 <= 64'b0;
            scause_q               <= 64'b0;
            stvec_q                <= 64'b0;
            sscratch_q             <= 64'b0;
            stval_q                <= 64'b0;
            satp_q                 <= 64'b0;
            // timer and counters
            cycle_q                <= 64'b0;
            instret_q              <= 64'b0;
            // aux registers
            en_ld_st_translation_q <= 1'b0;
            // wait for interrupt
            wfi_q                  <= 1'b0;
        end else begin
            priv_lvl_q             <= priv_lvl_d;
            // floating-point registers
            fcsr_q                 <= fcsr_d;
            // machine mode registers
            mstatus_q              <= mstatus_d;
            mtvec_q                <= mtvec_d;
            medeleg_q              <= medeleg_d;
            mideleg_q              <= mideleg_d;
            mip_q                  <= mip_d;
            mie_q                  <= mie_d;
            mepc_q                 <= mepc_d;
            mcause_q               <= mcause_d;
            mscratch_q             <= mscratch_d;
            mtval_q                <= mtval_d;
            dcache_q               <= dcache_d;
            icache_q               <= icache_d;
            // supervisor mode registers
            sepc_q                 <= sepc_d;
            scause_q               <= scause_d;
            stvec_q                <= stvec_d;
            sscratch_q             <= sscratch_d;
            stval_q                <= stval_d;
            satp_q                 <= satp_d;
            // timer and counters
            cycle_q                <= cycle_d;
            instret_q              <= instret_d;
            // aux registers
            en_ld_st_translation_q <= en_ld_st_translation_d;
            // wait for interrupt
            wfi_q                  <= wfi_d;
        end
    end

    //-------------
    // Assertions
    //-------------
    `ifndef SYNTHESIS
    `ifndef VERILATOR
        // check that eret and ex are never valid together
        assert property (
          @(posedge clk_i) !(eret_o && ex_i.valid))
        else begin $error("eret and exception should never be valid at the same time"); $stop(); end
    `endif
    `endif
endmodule
