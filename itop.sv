// =============================================================================
// itop.sv - Testbench Top for Icarus Verilog
// =============================================================================
// This module provides a self-contained testbench for simulating the RISC-V
// processor using Icarus Verilog. It generates the clock and reset signals,
// instantiates the processor, and handles simulation termination.
//
// Note: This file is used for Icarus Verilog. Verilator uses verilator_top.cpp
// as its testbench wrapper instead.

`include "top.sv"

// Time scale for simulation: 1 nanosecond time unit, 1 picosecond precision
`timescale 1ns / 1ps

// =============================================================================
// Testbench Module
// =============================================================================

module itop();

    // -----------------------------------------------------------------------------
    // Internal Signals
    // -----------------------------------------------------------------------------
    // Testbench signals that connect to the processor top module.

    logic clk = 0;    // Clock signal (starts at 0)
    logic reset = 1;  // Reset signal (active high, starts asserted)
    logic halt;       // Halt signal from processor (terminates simulation)

    // -----------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -----------------------------------------------------------------------------
    // Instantiate the processor top module

    top the_top(
        .clk(clk)
        ,.reset(reset)
        ,.halt(halt)
    );

    // -----------------------------------------------------------------------------
    // Clock Generation
    // -----------------------------------------------------------------------------
    // Generate a 100MHz clock (10ns period, 5ns half-period)
    // Clock toggles every 5 time units

    always #5 clk = ~clk;

    // -----------------------------------------------------------------------------
    // Reset and Simulation Control
    // -----------------------------------------------------------------------------

    initial begin
        // Enable waveform dumping for GTKWave viewing
        $dumpfile("test.vcd");
        $dumpvars(0);  // Dump all signals
        
        // Assert reset and hold for 16 time units (1.6 clock cycles)
        reset = 1;
        #16 reset = 0;  // De-assert reset
    end

    // -----------------------------------------------------------------------------
    // Simulation Termination
    // -----------------------------------------------------------------------------
    // Check for halt signal and terminate simulation 15 time units after halt
    // is asserted. This gives time for final signals to propagate.

    always #15 if (halt == 1'b1) $finish;
 
endmodule
