// =============================================================================
// system.sv - System-wide Type Definitions
// =============================================================================
// This file defines the fundamental types and constants used throughout the
// RISC-V processor design. All other modules include this file to ensure
// consistent type definitions across the project.

// Prevent multiple inclusion of this header file
`ifndef _system_
`define _system_

// -----------------------------------------------------------------------------
// Word Size Configuration
// -----------------------------------------------------------------------------
// These parameters define the data width of the processor. RV32I uses 32-bit
// words, meaning all general-purpose registers and most operations work on
// 32-bit quantities.

`define word_size 32              // Width of data words in bits (RV32I = 32)
`define word_address_size 32      // Width of addresses in bits

// Derived constants for byte-level addressing
`define word_size_bytes (`word_size/8)           // 4 bytes per word
`define word_address_size_bytes (`word_address_size/8)  // 4 bytes per address

// -----------------------------------------------------------------------------
// User-Defined Tag Size
// -----------------------------------------------------------------------------
// Tags can be used for debugging, tracking, or custom extensions. This defines
// the width of the user_tag field in memory requests/responses.
`define user_tag_size 16

// -----------------------------------------------------------------------------
// Primary Data Type
// -----------------------------------------------------------------------------
// The 'word' type is the fundamental data unit of the processor - a 32-bit
// value representing either data or an address depending on context.
typedef logic [31:0] word;
`endif
