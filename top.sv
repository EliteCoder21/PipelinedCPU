// =============================================================================
// top.sv - Top-Level System Integration
// =============================================================================
// This module integrates the RISC-V core with its memory subsystem, creating
// a complete processor system. It instantiates:
// - The 5-stage pipelined core
// - Instruction memory (code_mem) for storing program instructions
// - Data memory (data_mem) for program data and I/O

`include "base.sv"
`include "memory.sv"
`include "lab6.sv"

// =============================================================================
// Top Module
// =============================================================================
// The top module serves as the system-on-chip (SoC) level, connecting the
// processor core to its external memory and providing simulation control signals.

module top(
    input clk,                // System clock
    input reset,              // Asynchronous reset (active high)
    output logic halt         // Indicates simulation should terminate
    );

    // -----------------------------------------------------------------------------
    // Memory Interface Signals
    // -----------------------------------------------------------------------------
    // Request/response pairs for instruction and data memory interfaces.
    // The core generates requests; memories provide responses.

    memory_io_req 	inst_mem_req;    // Request to instruction memory
    memory_io_rsp 	inst_mem_rsp;    // Response from instruction memory
    memory_io_req   data_mem_req;    // Request to data memory
    memory_io_rsp   data_mem_rsp;   // Response from data memory

    // -----------------------------------------------------------------------------
    // Processor Core
    // -----------------------------------------------------------------------------
    // The RISC-V pipeline that fetches, decodes, and executes instructions.

    core the_core(
        .clk(clk)
        ,.reset(reset)
        // Reset PC - where execution begins after reset
        ,.reset_pc(32'h0001_0000)
        // Instruction memory interface
        ,.inst_mem_req(inst_mem_req)
        ,.inst_mem_rsp(inst_mem_rsp)
        // Data memory interface
        ,.data_mem_req(data_mem_req)
        ,.data_mem_rsp(data_mem_rsp)
    );

    // -----------------------------------------------------------------------------
    // Instruction Memory
    // -----------------------------------------------------------------------------
    // Stores the program to be executed. Initialized from hex files at startup.
    // Size: 64KB starting at address 0x0001_0000.

    `memory #(
        .size(32'h0001_0000)
        ,.initialize_mem(true)
        ,.byte0("code0.hex")
        ,.byte1("code1.hex")
        ,.byte2("code2.hex")
        ,.byte3("code3.hex")
        ,.enable_rsp_addr(true)
        ) code_mem (
        .clk(clk)
        ,.reset(reset)
        ,.req(inst_mem_req)
        ,.rsp(inst_mem_rsp)
    );

    // -----------------------------------------------------------------------------
    // Data Memory
    // -----------------------------------------------------------------------------
    // Provides read/write storage for program data. Initialized from hex files.
    // Also handles special I/O addresses for simulation output and termination.
    // Size: 64KB starting at address 0x0001_0000.

    `memory #(
        .size(32'h0001_0000)
        ,.initialize_mem(true)
        ,.byte0("data0.hex")
        ,.byte1("data1.hex")
        ,.byte2("data2.hex")
        ,.byte3("data3.hex")
        ,.enable_rsp_addr(true)
        ) data_mem (
        .clk(clk)
        ,.reset(reset)
        ,.req(data_mem_req)
        ,.rsp(data_mem_rsp)
    );

    // -----------------------------------------------------------------------------
    // Simulation I/O Support
    // -----------------------------------------------------------------------------
    // These special addresses allow the program to:
    // - Output characters to the simulation console
    // - Signal the simulation to terminate

    // Character output: Writing to 0x0002_FFF8 outputs a character
    always @(posedge clk)
        if (data_mem_req.valid && data_mem_req.addr == `word_address_size'h0002_FFF8 &&
            data_mem_req.do_write != {(`word_address_size/8){1'b0}}) begin
            $write("%c", data_mem_req.data[7:0]);
        end

    // Halt signal: Writing to 0x0002_FFFC terminates the simulation
    always @(posedge clk)
        if (data_mem_req.valid && data_mem_req.addr == `word_address_size'h0002_FFFC &&
            data_mem_req.do_write != {(`word_address_size/8){1'b0}})
            halt <= true;
        else
            halt <= false;

endmodule
