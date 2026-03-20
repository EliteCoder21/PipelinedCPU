/*
================================================================================
five-stage.sv - Alternative Single-Module 5-Stage Pipeline (DEPRECATED)
================================================================================
NOTE: This file is commented out and NOT used in the current build.
      The active implementation is in lab6.sv, which uses a modular design
      with separate modules for each pipeline stage.

This file contains an alternative implementation of a 5-stage RISC-V pipeline
in a single module. While functionally complete, it lacks the modularity and
extensibility of lab6.sv. It is retained for reference and comparison.

PIPELINE STAGES:
  1. FETCH    - Retrieve instruction from memory, update PC
  2. DECODE   - Extract fields, read register file, decode immediate
  3. EXECUTE  - ALU operations, branch comparison
  4. MEMORY   - Load/store operations
  5. WRITEBACK - Write result to register file

KEY DIFFERENCES FROM lab6.sv:
  - Single monolithic module vs. separate stage modules
  - FSM-based pipeline control vs. explicit stage signals
  - No explicit forwarding paths
  - No hazard detection module
================================================================================
*/

`ifndef _core_v
`define _core_v

`include "system.sv"
`include "base.sv"
`include "memory_io.sv"
`include "memory.sv"

module core(
    input  logic       clk,
    input  logic       reset,
    input  logic [`word_address_size-1:0] reset_pc,

    output memory_io_req inst_mem_req,
    input  memory_io_rsp inst_mem_rsp,
    output memory_io_req data_mem_req,
    input  memory_io_rsp data_mem_rsp
);

    // =============================================================================
    // Pipeline Stage Enumeration
    // =============================================================================
    // Defines the current active stage of the pipeline FSM.

    typedef enum { stage_fetch, stage_decode, stage_execute, stage_mem, stage_writeback } stage_t;
    stage_t current_stage;

    // =============================================================================
    // Program Counter Logic
    // =============================================================================

    word pc;             // Current program counter
    word next_pc;        // Next PC (from branch/jump)
    logic pc_override;   // Flag to use next_pc instead of pc+4

    always @(posedge clk) begin
        if (reset)
            pc <= reset_pc;
        else if (current_stage == stage_writeback)
            pc <= pc_override ? next_pc : (pc + 4);
    end

    // Latch PC in decode stage for branch target calculation
    word pc_r;

    always @(posedge clk) begin
        if (current_stage == stage_decode)
            pc_r <= pc;
    end

    // =============================================================================
    // Instruction Fetch
    // =============================================================================

    word instruction;

    // Generate instruction memory request when in fetch stage
    always_comb begin
        inst_mem_req = '0;
        if (current_stage == stage_fetch) begin
            inst_mem_req.valid   = 1'b1;
            inst_mem_req.addr    = pc - reset_pc;
            inst_mem_req.do_read = 4'b1111;  // Read full word
        end
    end

    // Latch fetched instruction
    always @(posedge clk) begin
        if (reset)
            instruction <= '0;
        else if (current_stage == stage_fetch && inst_mem_rsp.valid)
            instruction <= inst_mem_rsp.data;
    end

    // =============================================================================
    // Register File
    // =============================================================================
    // 32 general-purpose registers (x0-x31). x0 is hardwired to 0.

    typedef logic [4:0] regname;
    word regfile [31:0];
    regname rs1, rs2, rd;
    word rs1_val, rs2_val;

    // Read with x0 = 0 handling
    assign rs1_val = (rs1 == 0) ? word'(0) : regfile[rs1];
    assign rs2_val = (rs2 == 0) ? word'(0) : regfile[rs2];

    // Debug output
    always @(posedge clk) begin
        if (!reset)
            $display("t0=%0h, t1=%0h, t2=%0h, pc=%0h", regfile[5], regfile[6], regfile[7], pc);
        if (data_mem_req.valid)
            $display("Mem Access: addr=%h do_write=%b data=%h", data_mem_req.addr, data_mem_req.do_write, data_mem_req.data);
    end

    // =============================================================================
    // Decode Stage
    // =============================================================================
    // Extract instruction fields and decode immediate values

    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;
    word imm_i, imm_s, imm_b, imm_u, imm_j;

    // Latched values (pipelined)
    logic [6:0] opcode_r;
    logic [2:0] funct3_r;
    logic [6:0] funct7_r;
    word imm_i_r, imm_s_r, imm_b_r, imm_u_r, imm_j_r;
    word rs1_val_r;
    word rs2_val_r;
    regname rd_r;

    // Extract fields from instruction word
    always_comb begin
        opcode = instruction[6:0];
        rd     = instruction[11:7];
        funct3 = instruction[14:12];
        rs1    = instruction[19:15];
        rs2    = instruction[24:20];
        funct7 = instruction[31:25];

        // Sign-extend immediates based on instruction type
        imm_i = {{20{instruction[31]}}, instruction[31:20]};
        imm_s = {{20{instruction[31]}}, instruction[31:25], instruction[11:7]};
        imm_b = {{19{instruction[31]}}, instruction[31], instruction[7],
                 instruction[30:25], instruction[11:8], 1'b0};
        imm_u = {instruction[31:12], 12'b0};
        imm_j = {{11{instruction[31]}}, instruction[31], instruction[19:12],
                 instruction[20], instruction[30:21], 1'b0};
    end

    // Latch decode results
    always @(posedge clk) begin
        if (current_stage == stage_decode) begin
            opcode_r   <= opcode;
            funct3_r   <= funct3;
            funct7_r   <= funct7;
            imm_i_r    <= imm_i;
            imm_s_r    <= imm_s;
            imm_b_r    <= imm_b;
            imm_u_r    <= imm_u;
            imm_j_r    <= imm_j;
            rs1_val_r  <= rs1_val;
            rs2_val_r  <= rs2_val;
            rd_r       <= rd;
        end
    end

    // =============================================================================
    // Pipeline FSM Control
    // =============================================================================
    // Advances through pipeline stages, with stall support for memory operations

    always @(posedge clk) begin
        if (reset)
            current_stage <= stage_fetch;
        else begin
            case (current_stage)
                stage_fetch:     current_stage <= stage_t'(inst_mem_rsp.valid ? stage_decode : stage_fetch);
                stage_decode:    current_stage <= stage_execute;
                stage_execute:   current_stage <= stage_mem;
                stage_mem: begin
                    // Stall on loads until memory responds
                    if (opcode_r == 7'b0000011) begin
                        current_stage <= stage_t'(data_mem_rsp.valid ? stage_writeback : stage_mem);
                    end else begin
                        current_stage <= stage_writeback;
                    end
                end
                stage_writeback: current_stage <= stage_fetch;
                default:         current_stage <= stage_fetch;
            endcase
        end
    end

    // =============================================================================
    // Execute Stage (ALU)
    // =============================================================================

    word alu_result;
    word exec_result;
    word mem_addr;
    word store_data;

    always_comb begin
        alu_result  = '0;
        mem_addr    = '0;
        store_data  = rs2_val_r;
        next_pc     = '0;
        pc_override = 1'b0;

        case (opcode_r)
            // R-type instructions (register-register operations)
            7'b0110011: begin
                case ({funct7_r, funct3_r})
                    {7'b0000000,3'b000}: alu_result = rs1_val_r + rs2_val_r;      // ADD
                    {7'b0100000,3'b000}: alu_result = rs1_val_r - rs2_val_r;      // SUB
                    {7'b0000000,3'b001}: alu_result = rs1_val_r << rs2_val_r[4:0]; // SLL
                    {7'b0000000,3'b010}: alu_result = ($signed(rs1_val_r) < $signed(rs2_val_r)) ? 1 : 0;  // SLT
                    {7'b0000000,3'b011}: alu_result = (rs1_val_r < rs2_val_r) ? 1 : 0;  // SLTU
                    {7'b0000000,3'b100}: alu_result = rs1_val_r ^ rs2_val_r;      // XOR
                    {7'b0000000,3'b101}: alu_result = rs1_val_r >> rs2_val_r[4:0]; // SRL
                    {7'b0100000,3'b101}: alu_result = $signed(rs1_val_r) >>> rs2_val_r[4:0]; // SRA
                    {7'b0000000,3'b110}: alu_result = rs1_val_r | rs2_val_r;      // OR
                    {7'b0000000,3'b111}: alu_result = rs1_val_r & rs2_val_r;      // AND
                    default: ;
                endcase
            end

            // I-type instructions (register-immediate operations)
            7'b0010011: begin
                case(funct3_r)
                    3'b000: alu_result = rs1_val_r + imm_i_r;                     // ADDI
                    3'b010: alu_result = ($signed(rs1_val_r) < $signed(imm_i_r)) ? 1 : 0;  // SLTI
                    3'b011: alu_result = (rs1_val_r < imm_i_r) ? 1 : 0;             // SLTIU
                    3'b100: alu_result = rs1_val_r ^ imm_i_r;                      // XORI
                    3'b110: alu_result = rs1_val_r | imm_i_r;                      // ORI
                    3'b111: alu_result = rs1_val_r & imm_i_r;                      // ANDI
                    3'b001: alu_result = rs1_val_r << rs2_val_r;                   // SLLI
                    3'b101: begin                                                    // SRLI/SRAI
                        if (funct7_r == 7'b0000000)
                            alu_result = rs1_val_r >> rs2_val_r;
                        else if (funct7_r == 7'b0100000)
                            alu_result = $signed(rs1_val_r) >>> rs2_val_r;
                    end
                    default: ;
                endcase
            end

            7'b0110111: alu_result = imm_u_r;           // LUI
            7'b0010111: alu_result = pc + imm_u_r;     // AUIPC

            7'b0000011: mem_addr = rs1_val_r + imm_i_r;  // Load address
            7'b0100011: mem_addr = rs1_val_r + imm_s_r;  // Store address

            // Branch instructions
            7'b1100011: begin
                case(funct3_r)
                    3'b000: pc_override = (rs1_val_r == rs2_val_r);               // BEQ
                    3'b001: pc_override = (rs1_val_r != rs2_val_r);               // BNE
                    3'b100: pc_override = ($signed(rs1_val_r) <  $signed(rs2_val_r));  // BLT
                    3'b101: pc_override = ($signed(rs1_val_r) >= $signed(rs2_val_r));  // BGE
                    3'b110: pc_override = (rs1_val_r < rs2_val_r);                // BLTU
                    3'b111: pc_override = (rs1_val_r >= rs2_val_r);               // BGEU
                    default: ;
                endcase
                next_pc = pc_r + imm_b_r;
            end

            7'b1101111: begin  // JAL
                alu_result  = pc_r + 4;
                pc_override = 1'b1;
                next_pc     = pc_r + imm_j_r;
            end

            7'b1100111: begin  // JALR
                alu_result  = pc_r + 4;
                pc_override = 1'b1;
                next_pc     = (rs1_val_r + imm_i_r) & ~1;
            end

            default: ;
        endcase
    end

    always @(posedge clk) begin
        if (current_stage == stage_execute)
            exec_result <= alu_result;
    end

    // =============================================================================
    // Memory Stage - Data Memory Request
    // =============================================================================

    word load_data;
    logic mem_req_valid;
    word mem_req_addr;
    word mem_req_data;
    logic [3:0] mem_req_do_read;
    logic [3:0] mem_req_do_write;

    always_comb begin
        mem_req_valid    = 1'b0;
        mem_req_addr     = '0;
        mem_req_data     = '0;
        mem_req_do_read  = 4'b0000;
        mem_req_do_write = 4'b0000;

        if (current_stage == stage_mem) begin
            case (opcode_r)
                7'b0000011: begin // Load operations
                    mem_req_valid   = 1'b1;
                    mem_req_addr    = rs1_val_r + imm_i_r;
                    case(funct3_r)
                        3'b000: mem_req_do_read = 4'b0001;  // LB
                        3'b001: mem_req_do_read = 4'b0011;  // LH
                        3'b010: mem_req_do_read = 4'b1111;  // LW
                        3'b100: mem_req_do_read = 4'b0001;  // LBU
                        3'b101: mem_req_do_read = 4'b0011;  // LHU
                        default: mem_req_do_read = 4'b0000;
                    endcase
                end
                7'b0100011: begin // Store operations
                    mem_req_valid    = 1'b1;
                    mem_req_addr     = rs1_val_r + imm_s_r;
                    mem_req_data     = rs2_val_r;
                    case(funct3_r)
                        3'b000: mem_req_do_write = 4'b0001;  // SB
                        3'b001: mem_req_do_write = 4'b0011;  // SH
                        3'b010: mem_req_do_write = 4'b1111;  // SW
                        default: mem_req_do_write = 4'b0000;
                    endcase
                end
                default: ;
            endcase
        end
    end

    // Registered memory request output
    always_ff @(posedge clk) begin
        if (reset) begin
            data_mem_req.valid    <= 1'b0;
            data_mem_req.addr     <= '0;
            data_mem_req.do_read  <= 4'b0000;
            data_mem_req.do_write <= 4'b0000;
            data_mem_req.data     <= '0;
        end else begin
            data_mem_req.valid    <= mem_req_valid;
            data_mem_req.addr     <= mem_req_addr;
            data_mem_req.do_read  <= mem_req_do_read;
            data_mem_req.do_write <= mem_req_do_write;
            data_mem_req.data     <= mem_req_data;
        end
    end

    // =============================================================================
    // Memory Stage - Load Data Handling
    // =============================================================================
    // Latches and sign-extends/zero-extends loaded data based on size

    always @(posedge clk) begin
        if (reset)
            load_data <= '0;
        else if (data_mem_rsp.valid) begin
            if (opcode_r == 7'b0000011) begin
                case(funct3_r)
                    3'b000: load_data <= {{24{data_mem_rsp.data[7]}},  data_mem_rsp.data[7:0]};   // LB (sign-extend)
                    3'b001: load_data <= {{16{data_mem_rsp.data[15]}}, data_mem_rsp.data[15:0]};  // LH (sign-extend)
                    3'b010: load_data <= data_mem_rsp.data;                                           // LW
                    3'b100: load_data <= {24'b0, data_mem_rsp.data[7:0]};                          // LBU (zero-extend)
                    3'b101: load_data <= {16'b0, data_mem_rsp.data[15:0]};                         // LHU (zero-extend)
                    default: load_data <= '0;
                endcase
            end
        end
    end

    // =============================================================================
    // Writeback Stage
    // =============================================================================
    // Writes ALU results or loaded data back to the register file

    integer i;
    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < 32; i = i + 1)
                regfile[i] <= '0;
        end
        if (current_stage == stage_writeback && rd_r != 0) begin
            case (opcode_r)
                // ALU operations
                7'b0110011,  // R-type
                7'b0010011,  // I-type arithmetic
                7'b0110111,  // LUI
                7'b0010111,  // AUIPC
                7'b1101111,  // JAL
                7'b1100111:   // JALR
                    regfile[rd_r] <= exec_result;
                // Loads
                7'b0000011:
                    regfile[rd_r] <= load_data;
                default: ;
            endcase
        end
    end

endmodule

`endif
*/

