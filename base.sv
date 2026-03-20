// =============================================================================
// base.sv - Base Definitions and Utility Macros
// =============================================================================
// This file provides common utility definitions that improve code readability.
// These definitions are shared across all modules in the processor design.

// Prevent multiple inclusion
`ifndef _base_
`define _base_

`ifdef verilator
typedef logic bool;
`endif

// -----------------------------------------------------------------------------
// Boolean Constant Aliases
// -----------------------------------------------------------------------------
// These localparam aliases make boolean expressions more readable in the code.
// Instead of writing 1'b1 or 1'b0, code can use 'true' or 'false' for clarity.

// Boolean true constant (logic value 1)
localparam true = 1'b1;

// Boolean false constant (logic value 0)
localparam false = 1'b0;

// Singular forms for consistency (alternative names)
localparam one = 1'b1;
localparam zero = 1'b0;

`endif
