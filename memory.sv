// =============================================================================
// memory.sv - Dual-Port Memory Module
// =============================================================================
// This module implements a byte-addressable memory for use as instruction
// and data memory in the RISC-V processor. The memory is organized as four
// byte lanes (big-endian within each word) to support efficient byte,
// halfword, and word accesses.

// Prevent multiple inclusion
`ifndef _memory_sv
`define _memory_sv

// Include required type definitions
`include "system.sv"
`include "memory_io.sv"

// =============================================================================
// Memory32 Module
// =============================================================================
// A synchronous, byte-addressable memory with independent read/write ports.
// Each byte is stored in a separate array, allowing partial word writes.

module memory32 #(
    // Memory size in bytes (must be power of 2)
    parameter size = 4096
    // Set to 1 to initialize memory from hex files at simulation start
    ,parameter initialize_mem = 0
    // Hex file paths for initialization (one per byte lane)
    ,parameter byte0 = "data0.hex"
    ,parameter byte1 = "data1.hex"
    ,parameter byte2 = "data2.hex"
    ,parameter byte3 = "data3.hex"
    // Echo address back in response (useful for debugging)
    ,parameter enable_rsp_addr = 1
    ) (
    input   clk
    ,input  reset

    // Memory request from processor
    ,input memory_io_req32  req
    // Memory response to processor
    ,output memory_io_rsp32 rsp
    );

    // Log2 of memory size (used for address indexing)
    localparam size_l2 = $clog2(size);

    // -----------------------------------------------------------------------------
    // Byte-Lane Storage Arrays
    // -----------------------------------------------------------------------------
    // Memory is organized as 4 separate byte arrays, one for each byte position
    // within a word. This enables byte-level writes without read-modify-write.
    // Each array has size/4 entries (one entry per word-aligned address).
    
    reg [7:0]   data0[0:size/4 - 1];  // Byte 0 (least significant)
    reg [7:0]   data1[0:size/4 - 1];  // Byte 1
    reg [7:0]   data2[0:size/4 - 1];  // Byte 2
    reg [7:0]   data3[0:size/4 - 1];  // Byte 3 (most significant)

    // -----------------------------------------------------------------------------
    // Initialization
    // -----------------------------------------------------------------------------
    // Initialize all bytes to zero. Some simulators (Vivado) leave uninitialized
    // BRAM as 'X', which causes unpredictable behavior. Zero initialization
    // ensures clean simulation behavior.

    initial begin
        for (int i = 0; i < size/4; i++) begin
            data0[i] = 8'd0;
            data1[i] = 8'd0;
            data2[i] = 8'd0;
            data3[i] = 8'd0;
        end

        // Load initial program/data from hex files if requested
        if (initialize_mem) begin
            $readmemh(byte0, data0, 0);
            $readmemh(byte1, data1, 0);
            $readmemh(byte2, data2, 0);
            $readmemh(byte3, data3, 0);
        end
    end

    // -----------------------------------------------------------------------------
    // Memory Operation Logic
    // -----------------------------------------------------------------------------
    // Synchronous read/write on clock edge. The memory processes valid requests
    // and generates appropriate responses. Supports byte, halfword, and word
    // accesses based on the do_read/do_write byte enables.

    always @(posedge clk) begin
        // Default: no response pending
        rsp <= memory_io_no_rsp32;
        
        if (req.valid) begin
            rsp.user_tag <= req.user_tag;
            
            // Handle READ operation
            if (is_any_byte32(req.do_read)) begin
                if (enable_rsp_addr)
                    rsp.addr <= req.addr;
                rsp.valid <= 1'b1;
                // Construct word from individual byte lanes (big-endian)
                rsp.data[7:0] <= data0[req.addr[size_l2 - 1:2]];
                rsp.data[15:8] <= data1[req.addr[size_l2 - 1:2]];
                rsp.data[23:16] <= data2[req.addr[size_l2 - 1:2]];
                rsp.data[31:24] <= data3[req.addr[size_l2 - 1:2]];
                
            // Handle WRITE operation
            end else if (is_any_byte32(req.do_write)) begin
                if (enable_rsp_addr)
                    rsp.addr <= req.addr;
                rsp.valid <= 1'b1;
                // Write individual bytes based on byte enables
                if (req.do_write[0]) data0[req.addr[size_l2 - 1:2]] <= req.data[7:0];
                if (req.do_write[1]) data1[req.addr[size_l2 - 1:2]] <= req.data[15:8];
                if (req.do_write[2]) data2[req.addr[size_l2 - 1:2]] <= req.data[23:16];
                if (req.do_write[3]) data3[req.addr[size_l2 - 1:2]] <= req.data[31:24];
                
            // Invalid request (neither read nor write)
            end else begin
                rsp.valid <= 1'b0;
            end
        end
    end

endmodule


// -----------------------------------------------------------------------------
// Memory Width Configuration
// -----------------------------------------------------------------------------
// Select appropriate memory module based on architecture.
// Currently only 32-bit is implemented.

`ifdef __64bit__
`define memory memory64
`else
`define memory memory32
`endif

`endif
