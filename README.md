# PipelinedCPU

This project presents a complete, synthesizable implementation of a **5-stage pipelined RISC-V processor** compliant with the RV32I base integer instruction set architecture. Developed as the culminating project for the University of Washington's CSE 469: Computer Architecture course under the instruction of Mark Oskin, this implementation demonstrates fundamental concepts in modern processor design including instruction pipelining, data hazard mitigation through forwarding and stalling, branch misprediction handling, and modular digital system architecture.

The processor achieves instruction-level parallelism through a classical five-stage pipeline, processing one instruction per clock cycle under ideal conditions while maintaining strict architectural correctness through comprehensive hazard detection and recovery mechanisms. The design emphasizes clarity and modularity, with each pipeline stage implemented as an independent, well-documented module communicating through clearly defined interfaces. 

But what is the main difference between this implementation and a simple 5-stage CPU?  

## Architecture Overview

This processor implements a classical 5-stage pipeline architecture:

```
┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌───────────┐
│  FETCH  │───>│ DECODE  │───>│ EXECUTE │───>│ MEMORY  │───>│ WRITEBACK │
└─────────┘    └─────────┘    └─────────┘    └─────────┘    └───────────┘
```

### Pipeline Stages

1. **Fetch (IF)**: Retrieves instructions from instruction memory and updates the program counter (PC)
2. **Decode (ID)**: Decodes instruction fields, reads from register file, and extracts immediate values
3. **Execute (EX)**: Performs ALU operations, branch comparisons, and jump target computation
4. **Memory (MEM)**: Handles load/store operations to data memory
5. **Writeback (WB)**: Writes results back to the register file

### Key Features

- **RISC-V RV32I Base Instruction Set**: Supports all base integer instructions including:
  - Arithmetic: ADD, SUB, ADDI, SUBI
  - Logical: AND, OR, XOR, ANDI, ORI, XORI
  - Shifts: SLL, SRL, SRA, SLLI, SRLI, SRAI
  - Compare: SLT, SLTU, SLTI, SLTIU
  - Loads: LB, LH, LW, LBU, LHU
  - Stores: SB, SH, SW
  - Branches: BEQ, BNE, BLT, BGE, BLTU, BGEU
  - Jumps: JAL, JALR
  - Upper Immediates: LUI, AUIPC

- **Hazard Handling**: Detects and handles:
  - Load-use hazards (stalls pipeline)
  - Data hazards via forwarding paths
  - Branch misprediction detection and recovery

- **Data Forwarding**: Bypasses results from execute and memory stages to decode stage when register dependencies exist

- **Modular Design**: Each pipeline stage is implemented as a separate module with clear interfaces

## Project Structure

```
PipelinedCPU/
├── README.md              # This file
├── Makefile               # Build system
├── site-config.sh         # Tool configuration
├── top.sv                 # Top-level module integrating core with memories
├── lab6.sv                # Main pipeline implementation
│   ├── fetch              # Instruction fetch stage
│   ├── decode_and_writeback # Decode and register file
│   ├── execute            # ALU and branch execution
│   ├── memory             # Data memory operations
│   ├── writeback          # Result writeback
│   └── control            # Hazard detection and control
├── five-stage.sv          # Alternative single-module pipeline (commented out)
├── riscv.sv               # RISC-V package include file
├── riscv32_common.sv      # RISC-V type definitions and helper functions
├── system.sv              # System-wide type definitions
├── base.sv                # Base definitions and macros
├── memory.sv              # Dual-port memory module
├── memory_io.sv           # Memory interface definitions
├── itop.sv                # Testbench top for Icarus Verilog
├── verilator_top.cpp      # Verilator wrapper
├── start.s                # Sample RISC-V assembly program
├── test.c                 # C test program
├── elftohex.sh            # ELF to hex conversion script
├── dumphex.c              # Hex dump utility
└── ld.script              # Linker script
```

## Installation

### Prerequisites

- Docker

### Docker Environment

This project uses a Docker container with all necessary tools pre-installed. The container image is available on Docker Hub:

**https://hub.docker.com/r/therapy9903/cse469-tools**

To download the container, install Docker desktop and run:

```bash
docker pull therapy9903/cse469-tools
```

To run the container:

```bash
docker run --rm -it -v "${PWD}:/workspace" -w /workspace therapy9903/cse469-tools:latest
```

This mounts the current directory as `/workspace` inside the container and sets the working directory appropriately.

### Building the Project

Inside the Docker container, compile the project with:

```bash
make result-verilator
```

This will:
1. Compile the RISC-V test programs (`start.s`, `test.c`) to hex format
2. Build the Verilator simulation
3. Run the simulation

### Alternative: Icarus Verilog

To run with Icarus Verilog instead:

```bash
make result-iverilog
```

### Cleaning Build Artifacts

```bash
make clean
```

## Running Tests

The default test (`start.s`) executes a simple loop:

```asm
li t0, 1            # Initialize t0 = 1
li t1, 20           # Initialize t1 = 20

loop:
    addi t0, t0, 1  # Increment t0
    blt t0, t1, loop # Loop while t0 < t1

end:
    sw zero, 0(t2)   # Write to halt address
```

This simple program counts from 1 to 20 and then halts when we write to address `0x0002_FFFC.`

## Simulation Output

When run, the simulation displays:
- Register values each cycle (`REGS:`)
- Instruction execution (`EXEC:`)
- Branch decisions (`BRANCH:`)
- Memory operations (`MEMORY:`)
- Register updates (`DEBUG:`)

## Customizing Tests

To run custom RISC-V code:

1. Modify `start.s` or `test.c` with your assembly/C code
2. Rebuild with `make result-verilator`

## Technical Notes

### Memory Map

- **Instruction Memory**: 64KB starting at address `0x0001_0000`
- **Data Memory**: 64KB starting at address `0x0001_0000`
- **Halt Address**: `0x0002_FFFC` - Writing to this address stops simulation

### Hazard Handling

The control module implements:
- **Stalls**: For load-use hazards (when a load result is needed immediately)
- **Flushes**: For branch mispredictions (clears wrong-path instructions)
- **Forwarding**: Bypasses data from execute/memory stages to decode

### Reset Behavior

On reset:
- PC is set to `reset_pc` (default: `0x0001_0000`)
- All registers are cleared to zero
- All pipeline stages are invalidated

## License

See LICENSE file for details.

## Acknowledgments

This project was developed as part of a computer architecture course, implementing a classical RISC pipeline with educational emphasis on hazard handling and pipelining concepts.

## Errors

This is a class project of mine. As such, there are bound to be errors. If you see something that doesn't seem right, or something that could be explained better, please let me know. This would be a great learning experience for me and the Computer Architecture Community. Thanks for the read amazing human being!!
