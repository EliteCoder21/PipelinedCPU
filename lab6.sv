// ============================================================================
// lab6.sv - RISC-V Five-Stage Pipelined Processor
// ============================================================================
// This module implements a modularized, pipelined RISC-V processor without
// hazard handling or branch misprediction support. The pipeline consists of:
//   1. Fetch     - Retrieves instructions from instruction memory
//   2. Decode    - Decodes instruction fields and reads register file
//   3. Execute   - Performs ALU operations and branch target computation
//   4. Memory    - Handles load/store operations to data memory
//   5. Writeback - Writes results back to the register file
//
// The design uses structural structs to pass data between pipeline stages,
// allowing for clear interfaces and potential future enhancements like
// forwarding and branch prediction.

// Prevent multiple inclusion of this file
`ifndef __lab6_sv
`define __lab6_sv

// Include the common RISC-V definitions (opcodes, instruction formats, etc.)
// This file contains shared type definitions and helper functions used
// across all pipeline stages
`include "riscv.sv"

// ============================================================================
// Type Definitions for Pipeline Communication
// ============================================================================

// ----------------------------------------------------------------------------
// fetch_set_pc_call_t: Request to redirect the program counter
// ----------------------------------------------------------------------------
// Used to tell the fetch stage to jump to a new PC (e.g., after a branch
// misprediction or jump instruction). The 'valid' flag indicates whether
// the redirect should occur.
typedef struct packed {
    bool valid;              // Whether this PC redirect is active
    riscv::word pc;          // The target PC to fetch from next
} fetch_set_pc_call_t;

// ----------------------------------------------------------------------------
// fetch_set_pc_return_t: Response from fetch after PC redirect request
// ----------------------------------------------------------------------------
// Currently unused but provided for completeness in the fetch interface.
typedef struct packed {
    bool _unused_;           // Placeholder for future return data
} fetch_set_pc_return_t;

// ----------------------------------------------------------------------------
// stage_signal_t: Pipeline stage control signals
// ----------------------------------------------------------------------------
// Controls whether each pipeline stage should advance to the next instruction
// or flush/stall its current state. This is the primary mechanism for
// implementing hazard handling and recovery from mispredictions.
typedef struct packed {
    bool advance;            // Proceed to process next instruction
    bool flush;              // Clear current stage's output (e.g., after mispredict)
} stage_signal_t;

// ----------------------------------------------------------------------------
// fetched_instruction_t: Output from fetch stage, input to decode
// ----------------------------------------------------------------------------
// Holds the instruction word, its program counter, and validity flag.
// This is the main data product that flows from fetch to decode.
typedef struct packed {
    bool valid;                     // Whether instruction fetch succeeded
    riscv::instr32 instruction;      // The 32-bit instruction word
    riscv::word pc;                 // PC which this instruction was located
} fetched_instruction_t;

// ----------------------------------------------------------------------------
// local_instr_format: Local enum for RISC-V instruction formats
// ----------------------------------------------------------------------------
// RISC-V has several instruction formats (R, I, S, U, J) that differ in how
// they encode operands and immediates. This enum maps to those formats.
typedef enum {
     r_format = 0    // R-type: register-register operations (add, sub, etc.)
    ,i_format = 1    // I-type: register-immediate operations (addi, load, etc.)
    ,s_format = 2    // S-type: store instructions
    ,u_format = 3    // U-type: lui, auipc (upper immediates)
    ,j_format = 4    // J-type: jal (jump and link)
} local_instr_format;

// ============================================================================
// Instruction Format Decoding Functions
// ============================================================================

// ----------------------------------------------------------------------------
// decode_format_local: Determine instruction format from opcode
// ----------------------------------------------------------------------------
// Different RISC-V instruction types encode their fields differently.
// This function maps opcodes to their corresponding format for proper
// field extraction later in the pipeline.
function local_instr_format decode_format_local(riscv::opcode_q op_q);
    case (op_q)
        riscv::q_load, riscv::q_op_imm, riscv::q_jalr:  return i_format;  // Loads, immediate ops, jalr
        riscv::q_op:                    return r_format;  // R-type arithmetic
        riscv::q_store:                 return s_format;  // Stores
        riscv::q_lui, riscv::q_auipc:   return u_format;  // Upper immediates
        riscv::q_jal, riscv::q_branch:  return j_format;  // Jumps and branches
        default:                        return r_format;  // Default to R-type
    endcase
endfunction

// ----------------------------------------------------------------------------
// decode_imm_jal: Decode JAL immediate operand
// ----------------------------------------------------------------------------
// JAL (Jump And Link) stores a 20-bit immediate that encodes the jump offset.
// The encoding is: [31:31] [19:12] [20:20] [30:25] [24:21] -> need to
// sign-extend and shift left by 1 (lowest bit is always 0 for 32-bit alignment).
function riscv::word decode_imm_jal(riscv::instr32 instr);
    logic [19:0] imm;
    // Reconstruct the 20-bit immediate from scattered bit fields
    imm = {instr[31], instr[19:12], instr[20], instr[30:25], instr[24:21]};
    // Sign-extend to 32 bits and multiply by 2 (word-aligned jump)
    return { {11{imm[19]}}, imm, 1'b0 };
endfunction

// ----------------------------------------------------------------------------
// decode_imm_btype: Decode branch instruction immediate
// ----------------------------------------------------------------------------
// Branch instructions (BEQ, BNE, BLT, BGE, etc.) use a 12-bit immediate
// that encodes the branch offset. Similar to JAL, the bits are scattered
// across the instruction and require sign-extension.
function riscv::word decode_imm_btype(riscv::instr32 instr);
    logic [11:0] imm;
    // Reconstruct 12-bit immediate from: [31:31] [7:7] [30:25] [11:8]
    imm = {instr[31], instr[7], instr[30:25], instr[11:8]};
    // Sign-extend to 32 bits and multiply by 2 (word-aligned)
    return { {19{imm[11]}}, imm, 1'b0 };
endfunction

// ============================================================================
// FETCH STAGE
// ============================================================================
// The fetch stage retrieves instructions from instruction memory. It maintains
// the program counter (PC), requests instruction bytes from memory, and
// packages the fetched instruction for the decode stage. It also handles
// PC redirection (for jumps/branches) by accepting a fetch_set_pc_call.

module fetch(
    input logic       clk
    ,input logic      reset
    ,input logic      [`word_address_size-1:0] reset_pc  // Initial PC after reset

    // Stage control signalling - controls whether we fetch next instruction
    ,input stage_signal_t       fetch_signal_in

    // Control function interfaces - for PC redirection from later stages
    ,input fetch_set_pc_call_t    fetch_set_pc_call_in
    ,output fetch_set_pc_return_t  fetch_set_pc_return_out

    // Principle operation data path
    ,output memory_io_req           inst_mem_req      // Request to instruction memory
    ,input  memory_io_rsp           inst_mem_rsp      // Response from instruction memory
    ,output fetched_instruction_t   fetched_instruction_out  // Output to decode stage
    );

import riscv::*;

// ============================================================================
// Fetch Stage Internal State
// ============================================================================

// Program counter - the address of the next instruction to fetch
word fetch_pc;

// Flags to handle instruction stream clearing (when flushing after mispredict)
bool clear_fetch_stream;
word clear_to_this_pc;

// Latched instruction data - holds the fetched instruction between cycles
word issued_fetch_pc;
bool issued;
instr32 latched_instruction_read;       // The instruction word
bool latched_instruction_valid;          // Whether the latched data is valid
word latched_instruction_pc;             // PC of the latched instruction

// ============================================================================
// Combinational Logic: Generate Memory Request and Output
// ============================================================================
// This block runs every cycle to:
// 1. Generate memory read requests for the next instruction
// 2. Pass latched instruction to the decode stage
// 3. Handle instruction stream clearing when needed

always @(*) begin
    word memory_read = `word_size'd0;

    // Fill out the instruction memory request form
    // We only request if memory is ready AND we're allowed to advance
    inst_mem_req = memory_io_no_req;
    inst_mem_req.addr = fetch_pc;
    inst_mem_req.do_read[3:0] = 4'b1111;    // Read all 4 bytes (32-bit instruction)
    inst_mem_req.valid = inst_mem_rsp.ready && fetch_signal_in.advance;
    inst_mem_req.user_tag = 0;

    // Output the currently latched instruction to decode stage
    // (This is the instruction we fetched last cycle)
    fetched_instruction_out.valid = latched_instruction_valid;
    fetched_instruction_out.instruction = latched_instruction_read;
    fetched_instruction_out.pc = latched_instruction_pc;

    // Handle memory response - when instruction data returns from memory
    if (inst_mem_rsp.valid && fetch_signal_in.advance) begin
        if (clear_fetch_stream &&
            inst_mem_rsp.addr != clear_to_this_pc) begin
            // discard - don't pass this instruction to decode
        end else begin
            // Normal case: pass the fetched instruction to decode
            // Convert memory data to instruction format (handles endianness)
            memory_read = shuffle_store_data(inst_mem_rsp.data, inst_mem_rsp.addr);
            fetched_instruction_out.valid = true;
            fetched_instruction_out.instruction = memory_read[31:0];
            fetched_instruction_out.pc = inst_mem_rsp.addr;
        end
    end
end

// ============================================================================
// Sequential Logic: Update State on Clock Edge
// ============================================================================
// Handles:
// - PC updates (incrementing or redirecting)
// - Latching instruction data from memory responses
// - Reset behavior

always_ff @(posedge clk) begin
    // Reset logic - clear state and set PC to reset vector
    if (reset) begin
        fetch_pc <= reset_pc;
        latched_instruction_valid <= false;
        clear_fetch_stream <= false;
        clear_to_this_pc <= 0;
    // Normal operation
    end else begin
        // Only process if memory response is valid
        if (inst_mem_rsp.valid) begin
            // Reset issued flag - we're processing a response, not requesting
            issued <= false;

            if (clear_fetch_stream && inst_mem_rsp.addr != clear_to_this_pc) begin
                // do nothing - discard this response
            end else begin
                // Otherwise, latch the instruction data for next cycle
                clear_fetch_stream <= false;
                // Only latch if we're allowed to advance to next instruction
                if (fetch_signal_in.advance) begin
                    word memory_read;
                    // Convert memory data format to instruction
                    memory_read = shuffle_store_data(inst_mem_rsp.data, inst_mem_rsp.addr);
                    latched_instruction_pc <= inst_mem_rsp.addr;
                    latched_instruction_read <= memory_read[31:0];
                    latched_instruction_valid <= true;
                end
            end
        end

        // PC Update Logic:
        // After successfully requesting an instruction, advance PC by 4 bytes
        // (to the next sequential instruction). Note: This assumes no branches
        // are taken - branch prediction would modify this behavior.
        if (inst_mem_req.valid) begin
            fetch_pc <= fetch_pc + 4;
        end

        // Handle PC Redirection (from jumps/branches in later pipeline stages)
        if (fetch_set_pc_call_in.valid) begin
            $display("DEBUG FETCH: PC redirected to 0x%08h", fetch_set_pc_call_in.pc);
            fetch_pc <= fetch_set_pc_call_in.pc;
            latched_instruction_valid <= false;        // Invalidate current latched data
            clear_fetch_stream <= true;                // Mark that we're clearing
            clear_to_this_pc <= fetch_set_pc_call_in.pc;  // Remember target for filtering

        // If no redirect, ensure stream is not marked for clearing
        end else begin
            clear_fetch_stream <= false;
        end
    end
end

endmodule

// ============================================================================
// PIPELINE STRUCTS: DECODE STAGE OUTPUT
// ============================================================================
// These structs carry decoded instruction information through the pipeline.

typedef struct packed {
    bool valid;              // Whether this instruction is valid in decode stage
    riscv::tag rs1;          // Source register 1 address (5 bits)
    riscv::tag rs2;          // Source register 2 address
    riscv::word rd1;         // Value from source register 1
    riscv::word rd2;         // Value from source register 2
    riscv::word imm;         // Decoded immediate value
    riscv::tag wbs;         // Writeback destination register
    bool wbv;                // Whether this instruction writes back
    riscv::funct3 f3;        // Function field 3 (specifies operation variant)
    riscv::funct7 f7;       // Function field 7 (for R-type)
    riscv::opcode_q op_q;   // Opcode type (determines instruction type)
    riscv::instr_format format;  // Instruction format (R/I/S/U/J)
    riscv::instr32 instruction;  // Original instruction word
    riscv::word pc;          // Program counter of this instruction
    riscv::word decoded_rd1; // Copy of rs1 value (for debugging)
    riscv::word decoded_rd2; // Copy of rs2 value (for debugging)
} decoded_instruction_t;

// Writeback data structure - carries register write information
typedef struct packed {
    bool valid;              // Whether writeback is valid
    bool wbv;                // Whether to actually write
    riscv::tag wbs;          // Destination register address
    riscv::word wbd;         // Data to write
} writeback_instruction_t;

// Register file bypass structure - for forwarding logic
typedef struct packed {
    bool    valid;           // Whether bypass data is valid
    riscv::word    rd;       // Bypass data value
    riscv::tag     rs;       // Register being bypassed
} reg_file_bypass_t;

// ============================================================================
// DECODE AND WRITEBACK STAGE
// ============================================================================
// This module performs two functions:
// 1. DECODE: Extracts instruction fields (registers, immediates, function codes)
// 2. WRITEBACK: Writes results from completed instructions to register file

module decode_and_writeback (
    // Essential program signals
    input logic       clk
    ,input logic      reset

    // Stage control signalling - controls whether to process new instruction
    ,input stage_signal_t   decode_signal_in
    ,input stage_signal_t   execute_signal_in
    ,input stage_signal_t   writeback_signal_in

    // Control function interfaces - for register file bypassing
    ,output reg_file_bypass_t reg_file_bypass_out

    // Principle operation data path
    ,input fetched_instruction_t fetched_instruction_in
    ,output decoded_instruction_t decoded_instruction_out

    ,input writeback_instruction_t writeback_instruction_in
    );
    
import riscv::*;

// ============================================================================
// Register File
// ============================================================================
// The RISC-V register file has 32 general-purpose registers (x0-x31).
// x0 is hardwired to 0 in RISC-V architecture.

word    reg_file[0:31];     // 32-entry register file, each 32 bits

// Bypass path for forwarding - allows data to be read immediately after write
word    reg_file_bypass_rd;
tag     reg_file_bypass_rs;
bool    reg_file_bypass_valid;

// Combinational bypass output - immediately available to later stages
always_comb begin
    reg_file_bypass_out.valid = reg_file_bypass_valid;
    reg_file_bypass_out.rd = reg_file_bypass_rd;
    reg_file_bypass_out.rs = reg_file_bypass_rs;
end

// Tag tracking for potential future hazard detection
tag last_decode_instruction_rs1;
tag last_decode_instruction_rs2;

// ============================================================================
// Register File Initialization
// ============================================================================
// Initialize all registers to zero at simulation start.
// RISC-V x0 is architecturally hardwired to 0, but we initialize all for clarity.

initial begin
    for (int i = 0; i < 32; i++)
        reg_file[i] = `word_size'd0;
end

// ============================================================================
// Decode and Writeback Logic (Clocked)
// ============================================================================
// Performs:
// - Reading source registers from register file
// - Decoding immediate values
// - Determining writeback destination
// - Writing back results from memory stage

always_ff @(posedge clk) begin
    // Local variables for decode operation
    word    wbd;
    tag     rs1;
    tag     rs2;
    opcode_q op_q;
    instr_format format;
    tag read_reg_rs1;
    tag read_reg_rs2;
    word rs1_val;
    word rs2_val;
    
    // Step 1: Decode source register addresses from instruction
    rs1 = decode_rs1(fetched_instruction_in.instruction);
    rs2 = decode_rs2(fetched_instruction_in.instruction);
    op_q = decode_opcode_q(fetched_instruction_in.instruction);

    // Step 2: Determine instruction format (R/I/S/U/J)
    format = local_instr_format'(decode_format_local(op_q));

    // Step 3: Read source register values
    // x0 is hardwired to 0 - check before indexing register file
    rs1_val = (rs1 == 5'd0) ? `word_size'd0 : reg_file[rs1];
    rs2_val = (rs2 == 5'd0) ? `word_size'd0 : reg_file[rs2];

    // Step 4: Forward from writeback if there's a data hazard
    // (data being written now should be readable immediately)
    if (writeback_instruction_in.valid && writeback_instruction_in.wbv && writeback_instruction_in.wbs != 5'd0) begin
        if (rs1 == writeback_instruction_in.wbs) begin
            rs1_val = writeback_instruction_in.wbd;
        end
        if (rs2 == writeback_instruction_in.wbs) begin
            rs2_val = writeback_instruction_in.wbd;
        end
    end

    // Reset handling - invalidate bypass on reset
    if (reset)
        reg_file_bypass_valid <= false;

    // Step 5: Decode and output the instruction (or flush if signaled)
    if (reset || decode_signal_in.flush) begin
        decoded_instruction_out <= {($bits(decoded_instruction_t)){1'b0}};
        decoded_instruction_out.valid <= false;

    // Normal operation - decode the fetched instruction
    end else begin
        if (decode_signal_in.advance && fetched_instruction_in.valid) begin
            decoded_instruction_out.valid <= true;
            decoded_instruction_out.rs1 <= rs1;
            decoded_instruction_out.rs2 <= rs2;
            decoded_instruction_out.rd1 <= rs1_val;
            decoded_instruction_out.rd2 <= rs2_val;
            decoded_instruction_out.decoded_rd1 <= rs1_val;
            decoded_instruction_out.decoded_rd2 <= rs2_val;
            decoded_instruction_out.wbs <= decode_rd(fetched_instruction_in.instruction);
            decoded_instruction_out.f3 <= decode_funct3(fetched_instruction_in.instruction);
            decoded_instruction_out.op_q <= op_q;
            decoded_instruction_out.format <= format;

            // Step 6: Decode immediate value based on instruction format
            // Different formats have different immediate encodings
            decoded_instruction_out.imm <= (op_q == q_jal) ? 
                decode_imm_jal(fetched_instruction_in.instruction) : 
                (op_q == q_branch) ?
                decode_imm_btype(fetched_instruction_in.instruction) :
                decode_imm(fetched_instruction_in.instruction, format);

            decoded_instruction_out.wbv <= decode_writeback(op_q);
            decoded_instruction_out.f7 <= decode_funct7(fetched_instruction_in.instruction, format);
            decoded_instruction_out.pc <= fetched_instruction_in.pc;
            decoded_instruction_out.instruction <= fetched_instruction_in.instruction;
        end else begin
            decoded_instruction_out <= {($bits(decoded_instruction_t)){1'b0}};
            decoded_instruction_out.valid <= false;
        end
    end

    // Step 7: Writeback - update register file with completed operation
    if (!reset
        && writeback_signal_in.advance
        && writeback_instruction_in.valid
        && writeback_instruction_in.wbv
        && writeback_instruction_in.wbs != 5'd0) begin
        $display("DEBUG: Register x%0d <= 0x%08h", 
                 writeback_instruction_in.wbs, 
                 writeback_instruction_in.wbd);
        reg_file[writeback_instruction_in.wbs] <= writeback_instruction_in.wbd;
        // Set up bypass path for subsequent instructions
        reg_file_bypass_rs <= writeback_instruction_in.wbs;
        reg_file_bypass_rd <= writeback_instruction_in.wbd;
        reg_file_bypass_valid <= true;
    end

    // Debug: Display JAL immediate
    if (op_q == q_jal) begin
        $display("DECODE JAL: instr=%x imm=%x", fetched_instruction_in.instruction, decode_imm(fetched_instruction_in.instruction, format));
    end

    // Debug: Dump all register values each cycle
    $display("REGS: %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x",
             reg_file[0], reg_file[1], reg_file[2], reg_file[3], reg_file[4], reg_file[5], reg_file[6], reg_file[7],
             reg_file[8], reg_file[9], reg_file[10], reg_file[11], reg_file[12], reg_file[13], reg_file[14], reg_file[15],
             reg_file[16], reg_file[17], reg_file[18], reg_file[19], reg_file[20], reg_file[21], reg_file[22], reg_file[23],
             reg_file[24], reg_file[25], reg_file[26], reg_file[27], reg_file[28], reg_file[29], reg_file[30], reg_file[31]);

end
endmodule

// ============================================================================
// EXECUTE STAGE OUTPUT STRUCT
// ============================================================================

// Executed instruction struct - carries ALU result and writeback info
typedef struct packed {
    bool valid;
    riscv::word rd1;              // First operand value
    riscv::word rd2;              // Second operand value
    riscv::tag rs1;               // Source register 1 tag
    riscv::tag rs2;               // Source register 2 tag
    riscv::funct3 f3;              // Function code
    riscv::opcode_q op_q;         // Opcode type
    writeback_instruction_t writeback_instruction;  // Writeback info
} executed_instruction_t;

// PC control struct - communicates branch/jump decisions to fetch
typedef struct packed {
    bool fetch_mispredict;        // Whether a misprediction occurred
    bool wrong_pc;                // Whether PC was wrong
    riscv::word correct_pc;        // The correct target PC
}   pc_control_t;

// Memory stage instruction struct
typedef struct packed {
    bool valid;
    riscv::word pc;
    riscv::word exec_result;      // Result from execute stage
    riscv::funct3 f3;
    riscv::opcode_q op_q;
    writeback_instruction_t writeback_instruction;
} memory_instruction_t;

// ============================================================================
// EXECUTE STAGE
// ============================================================================
// The execute stage performs:
// 1. ALU operations (arithmetic, logical, shifts)
// 2. Branch comparison and target computation
// 3. Jump target computation
// 4. Data forwarding from in-flight instructions

module execute (
    input logic       clk
    ,input logic      reset
    ,input riscv::word       reset_pc

    // Stage control signalling
    ,input stage_signal_t   execute_signal_in
    ,input stage_signal_t   memory_signal_in

    // For detecting a branch mispredict (input from fetch)
    ,input fetched_instruction_t fetched_instruction_in

    // For bypassing - forward from memory and execute stages
    ,input reg_file_bypass_t reg_file_bypass_in
    ,input executed_instruction_t executed_instruction_in
    ,input writeback_instruction_t writeback_instruction_in
    ,input memory_instruction_t memory_instruction_in

    // Datapath proper
    ,input decoded_instruction_t  decoded_instruction_in
    ,output executed_instruction_t executed_instruction_out

    ,output pc_control_t pc_control_out
    );

import riscv::*;

// ============================================================================
// Execute Stage Internal Variables
// ============================================================================

word pc;                              // PC tracking
ext_operand exec_result_comb;         // ALU result (combinational)
word next_pc_comb;                    // Next PC (combinational)
word exec_bypassed_rd1_comb;          // Operand 1 after forwarding
word exec_bypassed_rd2_comb;          // Operand 2 after forwarding
word exec_bypassed_rd1_mem;           // Bypass from memory stage
word exec_bypassed_rd2_mem;

// ============================================================================
// Combinational Execute Logic
// ============================================================================
// Performs:
// - Operand selection (with forwarding from memory/execute stages)
// - ALU operation execution
// - Branch comparison
// - Next PC computation
// - Branch misprediction detection

always @(*) begin
    // Local variables for computation
    word rd1;
    word rd2;
    ext_operand branch_result;

    // Get input values (x0 reads as 0)
    rd1 = ((decoded_instruction_in.rs1 == 5'd0) ? `word_size'd0 : decoded_instruction_in.rd1);
    rd2 = ((decoded_instruction_in.rs2 == 5'd0) ? `word_size'd0 : decoded_instruction_in.rd2);

    // Initialize bypassed values to direct inputs
    exec_bypassed_rd1_comb = rd1;
    exec_bypassed_rd2_comb = rd2;

    // =========================================================================
    // Forwarding Logic (Bypass from Memory Stage)
    // =========================================================================
    // If the instruction in memory stage writes back, forward its result
    // to replace the current operand if there's a register match.
    if (decoded_instruction_in.valid) begin
        if (memory_instruction_in.valid && memory_instruction_in.writeback_instruction.wbv) begin
            if (decoded_instruction_in.rs1 == memory_instruction_in.writeback_instruction.wbs && decoded_instruction_in.rs1 != 5'd0) begin
                exec_bypassed_rd1_comb = memory_instruction_in.writeback_instruction.wbd;
            end
            if (decoded_instruction_in.rs2 == memory_instruction_in.writeback_instruction.wbs && decoded_instruction_in.rs2 != 5'd0) begin
                exec_bypassed_rd2_comb = memory_instruction_in.writeback_instruction.wbd;
            end
        end

        // Forwarding from Execute stage (result computed but not yet written)
        if (executed_instruction_in.valid && executed_instruction_in.writeback_instruction.wbv) begin
            if (decoded_instruction_in.rs1 == executed_instruction_in.writeback_instruction.wbs && decoded_instruction_in.rs1 != 5'd0) begin
                exec_bypassed_rd1_comb = executed_instruction_in.writeback_instruction.wbd;
            end
            if (decoded_instruction_in.rs2 == executed_instruction_in.writeback_instruction.wbs && decoded_instruction_in.rs2 != 5'd0) begin
                exec_bypassed_rd2_comb = executed_instruction_in.writeback_instruction.wbd;
            end
        end
    end

    // =========================================================================
    // ALU Execution
    // =========================================================================
    // Perform the actual operation based on opcode and function fields.
    // The execute() function (from riscv.sv) handles all RISC-V operations.
    exec_result_comb = execute(
        cast_to_ext_operand(exec_bypassed_rd1_comb),
        cast_to_ext_operand(exec_bypassed_rd2_comb),
        cast_to_ext_operand(decoded_instruction_in.imm),
        decoded_instruction_in.pc,
        decoded_instruction_in.op_q,
        decoded_instruction_in.f3,
        decoded_instruction_in.f7);

    // =========================================================================
    // Branch Comparison
    // =========================================================================
    // For branch instructions, compute rs1 - rs2 to determine condition
    branch_result = 0;
    if (decoded_instruction_in.op_q == q_branch) begin
        branch_result = cast_to_ext_operand(exec_bypassed_rd1_comb) - cast_to_ext_operand(exec_bypassed_rd2_comb);
    end

    // =========================================================================
    // Next PC Computation
    // =========================================================================
    // Determine the next program counter based on instruction type:
    // - JAL: PC + immediate (link address is PC + 4)
    // - JALR: Register value + immediate
    // - Branch: PC + immediate if branch taken, else PC + 4
    // - Default: PC + 4 (sequential execution)
    next_pc_comb = compute_next_pc(
        cast_to_ext_operand(exec_bypassed_rd1_comb),
        branch_result,
        decoded_instruction_in.imm,
        decoded_instruction_in.pc,
        decoded_instruction_in.op_q,
        decoded_instruction_in.f3);

    // Debug: Display branch information
    if (decoded_instruction_in.op_q == q_branch) begin
        $display("BRANCH: PC=%x rs1=%x rs2=%x imm=%x branch_res=%x f3=%b nextpc=%x pc+4=%x valid=%b",
                 decoded_instruction_in.pc, exec_bypassed_rd1_comb, exec_bypassed_rd2_comb,
                 decoded_instruction_in.imm, branch_result, decoded_instruction_in.f3,
                 next_pc_comb, decoded_instruction_in.pc + 4, decoded_instruction_in.valid);
    end

    // Initialize PC control (no misprediction assumed)
    pc_control_out = {($bits(pc_control_t)){1'b0}};
    pc_control_out.fetch_mispredict = false;

    // =========================================================================
    // Branch/Jump Misprediction Detection
    // =========================================================================
    // Compare predicted next PC (sequential) with actual target.
    // If they differ, signal misprediction to flush pipeline.
    if (decoded_instruction_in.valid
        && (decoded_instruction_in.op_q == q_branch
            || decoded_instruction_in.op_q == q_jal
            || decoded_instruction_in.op_q == q_jalr)
        && next_pc_comb != decoded_instruction_in.pc + 4) begin
        $display("MISPREDICT: PC=%x nextpc=%x pc+4=%x", decoded_instruction_in.pc, next_pc_comb, decoded_instruction_in.pc + 4);
        pc_control_out.fetch_mispredict = true;
        pc_control_out.correct_pc = next_pc_comb;
    end

    // Debug: Display JAL information
    if (decoded_instruction_in.op_q == q_jal) begin
        $display("JAL: PC=%x imm=%x next_pc=%x", decoded_instruction_in.pc, decoded_instruction_in.imm, next_pc_comb);
    end
end

// ============================================================================
// Sequential Execute Logic
// ============================================================================
// Latches the execute results on clock edge for pipeline progression.

always_ff @(posedge clk) begin
    // Reset: clear valid flag and reset PC tracking
    if (reset) begin
        executed_instruction_out.valid <= false;
        pc <= reset_pc;
    // Normal operation
    end else begin
        // If decode output is valid and we're advancing, process instruction
        if (decoded_instruction_in.valid && execute_signal_in.advance) begin
            $display("EXEC: PC=%x instr=%x nextpc=%x", decoded_instruction_in.pc, decoded_instruction_in.instruction, next_pc_comb);
            executed_instruction_out.valid <= true;
            pc <= next_pc_comb;

            // Pass through operand values
            executed_instruction_out.rd1 <= exec_bypassed_rd1_comb;
            executed_instruction_out.rd2 <= exec_bypassed_rd2_comb;
            executed_instruction_out.rs1 <= decoded_instruction_in.rs1;
            executed_instruction_out.rs2 <= decoded_instruction_in.rs2;
            
            // Set up writeback information
            executed_instruction_out.writeback_instruction.wbs <= decoded_instruction_in.wbs;
            executed_instruction_out.writeback_instruction.wbv <= decoded_instruction_in.wbv;
            executed_instruction_out.writeback_instruction.wbd <= exec_result_comb[`word_size-1:0];
            executed_instruction_out.writeback_instruction.valid <= decoded_instruction_in.valid;
            executed_instruction_out.f3 <= decoded_instruction_in.f3;
            executed_instruction_out.op_q <= decoded_instruction_in.op_q;
        // If we're stalling on memory, clear the output
        end else if (memory_signal_in.advance) begin
            executed_instruction_out <= {($bits(executed_instruction_t)){1'b0}};
            executed_instruction_out.valid <= false;
        end
    end
end

endmodule

// ============================================================================
// MEMORY STAGE
// ============================================================================
// The memory stage handles:
// 1. Load instructions - reading data from memory
// 2. Store instructions - writing data to memory
// 3. Passing through non-memory instructions to writeback

module memory (
    input logic       clk
    ,input logic      reset

    // Stage control signalling
    ,input stage_signal_t   memory_signal_in
    ,input stage_signal_t   writeback_signal_in

    // For bypassing - forward from writeback stage
    ,input reg_file_bypass_t reg_file_bypass_in
    ,input writeback_instruction_t writeback_instruction_in

    // Datapath proper
    ,output memory_io_req   data_mem_req      // Request to data memory
    ,input  memory_io_rsp   data_mem_rsp      // Response from data memory
    ,input executed_instruction_t  executed_instruction_in
    ,output memory_instruction_t memory_instruction_out

    );

import riscv::*;

// ============================================================================
// Memory Stage Combinational Logic
// ============================================================================
// Handles:
// - Computing memory addresses
// - Generating memory requests (reads/writes)
// - Bypassing register values for store addresses/data

always @(*) begin
    word  rd2;
    word  rd1;
    word  mem_addr;
    word  store_data;

    // Initialize to executed instruction values
    rd1 = executed_instruction_in.rd1;
    rd2 = executed_instruction_in.rd2;
    mem_addr = executed_instruction_in.writeback_instruction.wbd;
    store_data = rd2;

    // For store instructions, bypass values from writeback if there's a hazard
    if (executed_instruction_in.op_q == q_store) begin
        if (writeback_instruction_in.valid && writeback_instruction_in.wbv) begin
            if (executed_instruction_in.rs1 == writeback_instruction_in.wbs) begin
                mem_addr = writeback_instruction_in.wbd;
            end
            if (executed_instruction_in.rs2 == writeback_instruction_in.wbs) begin
                store_data = writeback_instruction_in.wbd;
            end
        end
    end

    // Initialize memory request to "no request"
    data_mem_req = memory_io_no_req;

    // Generate memory request for load/store/amo operations
    if (memory_signal_in.advance && executed_instruction_in.valid
        && (executed_instruction_in.op_q == q_store
         || executed_instruction_in.op_q == q_load
         || executed_instruction_in.op_q == q_amo)) begin
        data_mem_req.user_tag = 0;
        $display("MEMORY: op=%b addr=%x do_write=%b data=%x rs1=%b wbs=%b wbd=%x",
                 executed_instruction_in.op_q, 
                 mem_addr,
                 executed_instruction_in.f3,
                 store_data,
                 executed_instruction_in.rs1,
                 writeback_instruction_in.wbs,
                 writeback_instruction_in.wbd);
        
        // Handle STORE instructions
        if (executed_instruction_in.op_q == q_store) begin
            data_mem_req.addr = mem_addr[`word_address_size - 1:0];
            data_mem_req.valid = true;
            // Generate write mask based on store size (byte/halfword/word)
            data_mem_req.do_write = shuffle_store_mask(memory_mask(
                cast_to_memory_op(executed_instruction_in.f3)), mem_addr[`word_size - 1:0]);
            // Shuffle store data for memory endianness
            data_mem_req.data = shuffle_store_data(store_data, mem_addr[`word_size - 1:0]);
        end
        // Handle LOAD instructions
        else if (executed_instruction_in.op_q == q_load) begin
            data_mem_req.addr = executed_instruction_in.writeback_instruction.wbd[`word_address_size - 1:0];
            data_mem_req.valid = true;
            data_mem_req.do_read = shuffle_store_mask(memory_mask(
                cast_to_memory_op(executed_instruction_in.f3)), executed_instruction_in.writeback_instruction.wbd[`word_size - 1:0]);
        end
    end
end

// ============================================================================
// Memory Stage Sequential Logic
// ============================================================================
// Passes instruction information to writeback stage on clock edge.

always_ff @(posedge clk) begin
    if (memory_signal_in.advance) begin
        memory_instruction_out <= {($bits(memory_instruction_t)){1'b0}};
        if (executed_instruction_in.valid) begin
            // Pass through writeback information
            memory_instruction_out.writeback_instruction <= executed_instruction_in.writeback_instruction;
            memory_instruction_out.f3 <= executed_instruction_in.f3;
            memory_instruction_out.op_q <= executed_instruction_in.op_q;
            memory_instruction_out.valid <= executed_instruction_in.valid;
        end
    end else if (writeback_signal_in.advance)
        memory_instruction_out <= {($bits(memory_instruction_t)){1'b0}};
end

endmodule

// ============================================================================
// WRITEBACK STAGE
// ============================================================================
// The writeback stage:
// 1. For non-memory instructions: passes through the ALU result
// 2. For load instructions: receives data from memory and extracts correct portion
// 3. Forms the final writeback data structure for the register file

module writeback(
    input stage_signal_t writeback_signal_in
    ,input memory_io_rsp data_mem_rsp
    ,input memory_instruction_t memory_instruction_in
    ,output writeback_instruction_t writeback_instruction_out
    );

import riscv::*;

// ============================================================================
// Writeback Combinational Logic
// ============================================================================

always @(*) begin
    // Initialize to zero
    writeback_instruction_out = {($bits(writeback_instruction_t)){1'b0}};
    
    // Only process if signal says advance and memory has valid instruction
    if (writeback_signal_in.advance && memory_instruction_in.valid) begin
        // Pass through the writeback info from memory stage
        writeback_instruction_out = memory_instruction_in.writeback_instruction;
        
        // For load/amo operations, need to extract the correct data portion
        // and handle sign extension based on load size
        if (memory_instruction_in.op_q == q_load || memory_instruction_in.op_q == q_amo) begin
            writeback_instruction_out.wbd = subset_load_data(
                                shuffle_load_data(data_mem_rsp.data, memory_instruction_in.writeback_instruction.wbd[`word_size - 1:0]),
                                cast_to_memory_op(memory_instruction_in.f3));
            writeback_instruction_out.valid = data_mem_rsp.valid & memory_instruction_in.valid;
        end
    end
end

endmodule

// ============================================================================
// CONTROL STAGE (Hazard Detection and Pipeline Control)
// ============================================================================
// The control module detects:
// 1. Data hazards (load-use, register dependencies)
// 2. Branch mispredictions
// And generates stage control signals to handle them (stall or flush).

module control(
    input memory_io_rsp inst_mem_rsp
    ,input memory_io_rsp data_mem_rsp
    ,input pc_control_t pc_control_in
    ,input fetched_instruction_t fetched_instruction_in
    ,input decoded_instruction_t decoded_instruction_in
    ,input executed_instruction_t executed_instruction_in
    ,input memory_instruction_t memory_instruction_in
    ,output stage_signal_t  fetch_signal_out
    ,output stage_signal_t  decode_signal_out
    ,output stage_signal_t  execute_signal_out
    ,output stage_signal_t  memory_signal_out
    ,output stage_signal_t  writeback_signal_out
    ,output fetch_set_pc_call_t fetch_set_pc_call_out
    );

    import riscv::*;

    // Hazard detection flags
    logic load_use_hazard;      // Load followed by dependent instruction
    logic data_hazard_ex;       // Hazard from execute stage
    logic data_hazard_mem;      // Hazard from memory stage
    logic branch_mispredict;    // Branch/jump was mispredicted

    // =========================================================================
    // Hazard Detection Logic
    // =========================================================================
    // Checks for register dependencies between pipeline stages.

    always_comb begin
        // Initialize flags
        load_use_hazard = false;
        data_hazard_ex = false;
        data_hazard_mem = false;
        branch_mispredict = false;

        // Check for data hazard from execute stage
        // Compare source registers in decode with destination in execute
        if (decoded_instruction_in.valid && executed_instruction_in.valid && executed_instruction_in.writeback_instruction.wbv) begin
            if (executed_instruction_in.writeback_instruction.wbs != 5'd0) begin
                if (decoded_instruction_in.rs1 == executed_instruction_in.writeback_instruction.wbs ||
                    decoded_instruction_in.rs2 == executed_instruction_in.writeback_instruction.wbs) begin
                    data_hazard_ex = true;
                end
            end
        end

        // Check for data hazard from memory stage
        if (decoded_instruction_in.valid && memory_instruction_in.valid && memory_instruction_in.writeback_instruction.wbv) begin
            if (memory_instruction_in.writeback_instruction.wbs != 5'd0) begin
                if (decoded_instruction_in.rs1 == memory_instruction_in.writeback_instruction.wbs ||
                    decoded_instruction_in.rs2 == memory_instruction_in.writeback_instruction.wbs) begin
                    data_hazard_mem = true;
                end
            end
        end

        // Check for load-use hazard (special case: load followed immediately by use)
        // This requires stalling because loaded data isn't available until after memory stage
        if (decoded_instruction_in.valid && executed_instruction_in.valid) begin
            if (executed_instruction_in.op_q == q_load && executed_instruction_in.writeback_instruction.wbv) begin
                if (executed_instruction_in.writeback_instruction.wbs != 5'd0) begin
                    if (decoded_instruction_in.rs1 == executed_instruction_in.writeback_instruction.wbs ||
                        decoded_instruction_in.rs2 == executed_instruction_in.writeback_instruction.wbs) begin
                        load_use_hazard = true;
                    end
                end
            end
        end

        // Get misprediction flag from execute stage
        branch_mispredict = pc_control_in.fetch_mispredict;

        // Debug: display misprediction
        if (pc_control_in.fetch_mispredict) begin
            $display("CONTROL: branch_mispredict from exec! correct_pc=%x", pc_control_in.correct_pc);
        end

        // =========================================================================
        // Default: All stages advance normally
        // =========================================================================
        fetch_signal_out.advance = true;
        fetch_signal_out.flush = false;
        decode_signal_out.advance = true;
        decode_signal_out.flush = false;
        execute_signal_out.advance = true;
        execute_signal_out.flush = false;
        memory_signal_out.advance = true;
        memory_signal_out.flush = false;
        writeback_signal_out.advance = true;
        writeback_signal_out.flush = false;
        fetch_set_pc_call_out.valid = false;

        // =========================================================================
        // Handle Load-Use Hazard: Stall the pipeline
        // =========================================================================
        // When a load is followed by an instruction that uses the loaded register,
        // we must stall to allow the data to propagate through the pipeline.
        if (load_use_hazard) begin
            fetch_signal_out.advance = false;
            decode_signal_out.advance = false;
            execute_signal_out.advance = false;
        end

        // =========================================================================
        // Handle Branch Misprediction: Flush and Redirect
        // =========================================================================
        // When a branch is mispredicted:
        // - Flush decode and execute stages (they have wrong-path instructions)
        // - Redirect fetch to correct PC
        if (branch_mispredict) begin
            fetch_signal_out.advance = true;
            fetch_signal_out.flush = true;
            decode_signal_out.advance = false;
            decode_signal_out.flush = true;
            execute_signal_out.advance = false;
            execute_signal_out.flush = true;
            fetch_set_pc_call_out.valid = true;
            fetch_set_pc_call_out.pc = pc_control_in.correct_pc;
        end

    end
endmodule

// ============================================================================
// CORE MODULE - Top-Level Pipeline Integration
// ============================================================================
// The core module integrates all five pipeline stages together, connecting
// the outputs of each stage to the inputs of the next. It instantiates:
// - Fetch stage
// - Decode/Writeback stage
// - Execute stage
// - Memory stage
// - Writeback stage
// - Control logic

module core #(
    parameter btb_enable = false          // BTB not implemented
    ) (
    input logic       clk
    ,input logic      reset
    ,input logic      [`word_address_size-1:0] reset_pc
    ,output memory_io_req   inst_mem_req
    ,input  memory_io_rsp   inst_mem_rsp
    ,output memory_io_req   data_mem_req
    ,input  memory_io_rsp   data_mem_rsp);

import riscv::*;

// ============================================================================
// Pipeline Control Signals
// ============================================================================
// These signals coordinate data flow between stages, controlling whether
// each stage advances, flushes, or stalls.

stage_signal_t fetch_signal, decode_signal, execute_signal, memory_signal, writeback_signal;

// Interface structs for fetch PC control
fetch_set_pc_call_t fetch_set_pc_call;
fetch_set_pc_return_t fetch_set_pc_return;

// Output from fetch - input to decode
fetched_instruction_t fetched_instruction;

// ============================================================================
// FETCH STAGE INSTANTIATION
// ============================================================================

fetch fetch_m(.clk(clk), .reset(reset)
    ,.reset_pc(reset_pc)
    ,.fetch_signal_in(fetch_signal)
    ,.fetch_set_pc_call_in(fetch_set_pc_call)
    ,.fetch_set_pc_return_out(fetch_set_pc_return)
    ,.inst_mem_req(inst_mem_req)
    ,.inst_mem_rsp(inst_mem_rsp)
    ,.fetched_instruction_out(fetched_instruction)
    );

// ============================================================================
// DECODE STAGE INSTANTIATION
// ============================================================================

reg_file_bypass_t reg_file_bypass;
decoded_instruction_t decoded_instruction;
writeback_instruction_t writeback_instruction;

decode_and_writeback decode_and_writeback_m(.clk(clk), .reset(reset)
    // Stage control signalling
    ,.decode_signal_in(decode_signal)
    ,.execute_signal_in(execute_signal)
    ,.writeback_signal_in(writeback_signal)
    // Control function interfaces
    ,.reg_file_bypass_out(reg_file_bypass)

    // Principle operation data path
    ,.fetched_instruction_in(fetched_instruction)
    ,.decoded_instruction_out(decoded_instruction)
    ,.writeback_instruction_in(writeback_instruction)
    );

// ============================================================================
// EXECUTE STAGE INSTANTIATION
// ============================================================================

executed_instruction_t executed_instruction;
pc_control_t pc_control;

execute execute_m(
    .clk(clk), .reset(reset)
    ,.reset_pc(reset_pc)
    ,.execute_signal_in(execute_signal)
    ,.memory_signal_in(memory_signal)

    ,.fetched_instruction_in(fetched_instruction)
    ,.reg_file_bypass_in(reg_file_bypass)
    ,.executed_instruction_in(executed_instruction)
    ,.writeback_instruction_in(writeback_instruction)
    ,.memory_instruction_in(memory_instruction)

    ,.decoded_instruction_in(decoded_instruction)
    ,.executed_instruction_out(executed_instruction)
    ,.pc_control_out(pc_control)
    );

// ============================================================================
// MEMORY STAGE INSTANTIATION
// ============================================================================

memory_instruction_t memory_instruction;

memory memory_m(
    .clk(clk), .reset(reset)
    ,.memory_signal_in(memory_signal)
    ,.writeback_signal_in(writeback_signal)

    ,.writeback_instruction_in(writeback_instruction)
    ,.reg_file_bypass_in(reg_file_bypass)

    ,.data_mem_req(data_mem_req)
    ,.data_mem_rsp(data_mem_rsp)
    ,.executed_instruction_in(executed_instruction)
    ,.memory_instruction_out(memory_instruction)
    );

// ============================================================================
// WRITEBACK STAGE INSTANTIATION
// ============================================================================

writeback writeback_m(
    .writeback_signal_in(writeback_signal)
    ,.data_mem_rsp(data_mem_rsp)
    ,.memory_instruction_in(memory_instruction)
    ,.writeback_instruction_out(writeback_instruction)
    );

// ============================================================================
// CONTROL MODULE INSTANTIATION
// ============================================================================

control control_m(
    .inst_mem_rsp(inst_mem_rsp)
    ,.data_mem_rsp(data_mem_rsp)
    ,.pc_control_in(pc_control)
    ,.fetched_instruction_in(fetched_instruction)
    ,.decoded_instruction_in(decoded_instruction)
    ,.executed_instruction_in(executed_instruction)
    ,.memory_instruction_in(memory_instruction)
    ,.fetch_signal_out(fetch_signal)
    ,.decode_signal_out(decode_signal)
    ,.execute_signal_out(execute_signal)
    ,.memory_signal_out(memory_signal)
    ,.writeback_signal_out(writeback_signal)
    ,.fetch_set_pc_call_out(fetch_set_pc_call)
    );

endmodule

`endif
