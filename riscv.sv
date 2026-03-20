// =============================================================================
// riscv.sv - RISC-V Package Selection
// =============================================================================
// This file selects the appropriate RISC-V implementation based on the target
// architecture (32-bit or 64-bit). The selected file provides all type
// definitions, opcodes, instruction formats, and helper functions needed
// by the processor implementation.

// Prevent multiple inclusion
`ifndef riscv_common_pkg
`define riscv_common_pkg

// Include system type definitions
`include "system.sv"

// =============================================================================
// RISC-V Package
// =============================================================================
// A SystemVerilog package that contains all RISC-V-specific types and functions.
// This package is imported by modules that need to work with RISC-V instructions.

package riscv;
`ifdef __64bit__
    // 64-bit RISC-V implementation
    `include "riscv64_common.sv"
`else
    // 32-bit RISC-V implementation (currently the only implemented variant)
    `include "riscv32_common.sv"
`endif
endpackage;

`endif