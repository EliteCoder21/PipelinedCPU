// =============================================================================
// memory_io.sv - Memory Interface Type Definitions
// =============================================================================
// This file defines the request/response structures used for communication
// between the processor core and memory modules. These interfaces support
// byte-level reads/writes for implementing RISC-V's byte and halfword loads/stores.

// Prevent multiple inclusion
`ifndef _memory_io_
`define _memory_io_

// Include system-wide type definitions (word, address sizes, etc.)
`include "system.sv"

// -----------------------------------------------------------------------------
// Memory Request Structure
// -----------------------------------------------------------------------------
// Used by the processor to request memory operations (read or write).
// The 'do_read' and 'do_write' fields use 4 bits to independently enable
// each byte lane, supporting byte (8-bit), halfword (16-bit), and word (32-bit)
// accesses at any byte-aligned address.

typedef struct packed {
    logic [`word_address_size-1:0]    addr;      // Memory address to access
    logic [31:0]                      data;     // Data to write (for stores)
    logic [3:0]                       do_read;  // Byte enable for read (bit[i]=1 enables byte i)
    logic [3:0]                       do_write; // Byte enable for write (bit[i]=1 writes byte i)
    logic                              valid;    // Request is valid and should be processed
    logic [2:0]                        dummy;    // Reserved/unused padding
    logic [`user_tag_size-1:0]         user_tag; // User-defined tag for debugging/extensions
}   memory_io_req32;

// Default/inactive request - all fields zeroed, ready signal asserted
localparam memory_io_no_req32 = { {(`word_address_size){1'b0}}, 32'b0, 4'b0, 4'b0, 1'b0, 3'b000, {(`user_tag_size){1'b0}} };

// -----------------------------------------------------------------------------
// Memory Response Structure
// -----------------------------------------------------------------------------
// Returned by memory modules to provide read data or acknowledge write completion.
// The 'ready' signal indicates when memory can accept new requests.

typedef struct packed {
    logic [`word_address_size-1:0]    addr;      // Address that was accessed (echoed back)
    logic [31:0]                       data;     // Read data (for load operations)
    logic                              valid;    // Response is valid (data is ready)
    logic                              ready;    // Memory is ready to accept new requests
    logic [1:0]                        dummy;    // Reserved/unused padding
    logic [`user_tag_size - 1:0]       user_tag; // User-defined tag (echoed from request)
}   memory_io_rsp32;

// Default/inactive response
localparam memory_io_no_rsp32 = { {(`word_address_size){1'b0}}, 32'd0, 1'b0, 1'b1, 2'b00, {(`user_tag_size){1'b0}} };

// -----------------------------------------------------------------------------
// Byte Enable Masks
// -----------------------------------------------------------------------------
// 4'b1111 indicates a full 32-bit word access (all 4 bytes enabled)

// Mask for reading/writing an entire word (all 4 bytes)
`define whole_word32  4'b1111

// -----------------------------------------------------------------------------
// Helper Functions for Byte Enable Logic
// -----------------------------------------------------------------------------
// These functions check if byte enables are active for various access sizes.

// Check if all 4 byte lanes are enabled (full word access)
function automatic logic is_whole_word32(logic [3:0] control);
    return control[0] & control[1] & control[2] & control[3];
endfunction

// Check if any byte lane is enabled (at least one byte being accessed)
function automatic logic is_any_byte32(logic [3:0] control);
    return control[0] | control[1] | control[2] | control[3];
endfunction


// -----------------------------------------------------------------------------
// Aliases for 32-bit Memory Interface
// -----------------------------------------------------------------------------
// For RV32 (32-bit) implementations, these are the primary types used.

typedef memory_io_req32     memory_io_req;
typedef memory_io_rsp32     memory_io_rsp;
localparam memory_io_no_req = memory_io_no_req32;
localparam memory_io_no_rsp = memory_io_no_rsp32;

// Wrapper functions that call the 32-bit versions
function automatic logic is_any_byte(logic [3:0] control);
    return is_any_byte32(control);
endfunction
function automatic logic is_whole_word(logic [3:0] control);
    return is_whole_word32(control);
endfunction


`endif
