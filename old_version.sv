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

    typedef logic [31:0] word;
    typedef logic [4:0]  regname;

    // ============================================================
    // PROGRAM COUNTER
    // ============================================================

    word pc;
    logic stall;
    logic flush;
    word branch_target;

    always_ff @(posedge clk) begin
        if (reset)
            pc <= reset_pc;
        else if (!stall)
            pc <= flush ? branch_target : pc + 4;
    end

    // ============================================================
    // REGISTER FILE
    // ============================================================

    word regfile [31:0];

    integer i;
    always_ff @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < 32; i++)
                regfile[i] <= 0;
        end
    end

    // ============================================================
    // IF / ID
    // ============================================================

    typedef struct packed {
        word pc;
        word inst;
        logic valid;
    } if_id_t;

    if_id_t if_id, if_id_next;

    always_comb begin
        inst_mem_req.valid    = !stall;
        inst_mem_req.addr     = pc - reset_pc;
        inst_mem_req.do_read  = 4'b1111;
        inst_mem_req.do_write = 4'b0000;
        inst_mem_req.data     = 32'b0;
    end

    always_comb begin
        if_id_next = if_id;

        if (!stall) begin
            if_id_next.pc    = pc;
            if_id_next.inst  = inst_mem_rsp.data;
            if_id_next.valid = inst_mem_rsp.valid;
        end

        if (flush)
            if_id_next.valid = 0;
    end

    // ============================================================
    // DECODE
    // ============================================================

    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;
    regname rs1, rs2, rd;

    always_comb begin
        opcode = if_id.inst[6:0];
        rd     = if_id.inst[11:7];
        funct3 = if_id.inst[14:12];
        rs1    = if_id.inst[19:15];
        rs2    = if_id.inst[24:20];
        funct7 = if_id.inst[31:25];
    end

    word rs1_val, rs2_val;

    always_comb begin
        rs1_val = (rs1 == 0) ? 0 : regfile[rs1];
        rs2_val = (rs2 == 0) ? 0 : regfile[rs2];
    end

    word imm_i, imm_s, imm_b, imm_u, imm_j;

    always_comb begin
        imm_i = {{20{if_id.inst[31]}}, if_id.inst[31:20]};
        imm_s = {{20{if_id.inst[31]}}, if_id.inst[31:25], if_id.inst[11:7]};
        imm_b = {{19{if_id.inst[31]}}, if_id.inst[31], if_id.inst[7],
                 if_id.inst[30:25], if_id.inst[11:8], 1'b0};
        imm_u = {if_id.inst[31:12], 12'b0};
        imm_j = {{11{if_id.inst[31]}}, if_id.inst[31], if_id.inst[19:12],
                 if_id.inst[20], if_id.inst[30:21], 1'b0};
    end

    // ============================================================
    // ID / EX
    // ============================================================

    typedef struct packed {
        word pc;
        word rs1_val;
        word rs2_val;
        word imm;
        regname rs1;
        regname rs2;
        regname rd;
        logic [6:0] opcode;
        logic [2:0] funct3;
        logic valid;
    } id_ex_t;

    id_ex_t id_ex, id_ex_next;

    // Load-use stall detection
    /*
    always_comb begin
        stall = 0;

        if (id_ex.valid &&
            id_ex.opcode == 7'b0000011 &&
            id_ex.rd != 0 &&
            (id_ex.rd == rs1 || id_ex.rd == rs2))
            stall = 1;
    end
    */

    // Load-use hazard detection
    logic load_use_hazard;

    always_comb begin
        load_use_hazard = 0;

        // Check if EX-stage instruction is a load
        if (id_ex.valid && id_ex.opcode == 7'b0000011 && id_ex.rd != 0) begin
            // Check if ID-stage instruction reads the same register
            if ((rs1 == id_ex.rd) || (rs2 == id_ex.rd && uses_rs2(opcode))) begin
                load_use_hazard = 1;
            end
        end
    end

    // Stall logic
    always_comb begin
        stall = load_use_hazard;
    end

    // Helper function to check if instruction uses rs2
    function logic uses_rs2(input logic [6:0] opc);
        case(opc)
            7'b0110011, // R-type
            7'b0100011, // SW
            7'b1100011: // BEQ/BNE
                uses_rs2 = 1;
            default:
                uses_rs2 = 0;
        endcase
    endfunction

    always_comb begin
        id_ex_next = id_ex;

        if (stall)
            id_ex_next.valid = 0;
        else begin
            id_ex_next.pc      = if_id.pc;
            id_ex_next.rs1_val = rs1_val;
            id_ex_next.rs2_val = rs2_val;
            id_ex_next.rs1     = rs1;
            id_ex_next.rs2     = rs2;
            id_ex_next.rd      = rd;
            id_ex_next.opcode  = opcode;
            id_ex_next.funct3  = funct3;
            id_ex_next.valid   = if_id.valid;

            case (opcode)
                7'b0010011,
                7'b0000011,
                7'b1100111: id_ex_next.imm = imm_i;
                7'b0100011: id_ex_next.imm = imm_s;
                7'b1100011: id_ex_next.imm = imm_b;
                7'b1101111: id_ex_next.imm = imm_j;
                7'b0110111,
                7'b0010111: id_ex_next.imm = imm_u;
                default: id_ex_next.imm = 0;
            endcase
        end

        if (flush)
            id_ex_next.valid = 0;
    end

    // ============================================================
    // FORWARDING + EXECUTE
    // ============================================================

    typedef struct packed {
        word alu_result;
        word rs2_val;
        regname rd;
        logic [6:0] opcode;
        logic valid;
    } ex_mem_t;

    ex_mem_t ex_mem, ex_mem_next;

    word fwd_rs1, fwd_rs2;

    always_comb begin
        // default
        fwd_rs1 = id_ex.rs1_val;
        fwd_rs2 = id_ex.rs2_val;

        // EX stage forwarding
        if (ex_mem.valid && ex_mem.rd != 0 && ex_mem.rd == id_ex.rs1)
            fwd_rs1 = ex_mem.alu_result;
        if (ex_mem.valid && ex_mem.rd != 0 && ex_mem.rd == id_ex.rs2)
            fwd_rs2 = ex_mem.alu_result;

        // MEM stage forwarding
        if (mem_wb.valid && mem_wb.reg_write && mem_wb.rd != 0) begin
            if (mem_wb.rd == id_ex.rs1) fwd_rs1 = mem_wb.result;
            if (mem_wb.rd == id_ex.rs2) fwd_rs2 = mem_wb.result;
        end
    end

    word alu_result;
    logic branch_taken;

    always_comb begin
        alu_result   = 0;
        branch_taken = 0;
        branch_target = 0;

        case (id_ex.opcode)
            7'b0110111: alu_result = id_ex.imm;           // LUI
            7'b0110011: alu_result = fwd_rs1 + fwd_rs2;   // ADD/SUB simplified
            7'b0010011: alu_result = fwd_rs1 + id_ex.imm; // ADDI
            7'b0000011,
            7'b0100011: alu_result = fwd_rs1 + id_ex.imm; // LW/SW
            7'b1100011: begin                              // BEQ (simplified as equality)
                branch_taken  = (fwd_rs1 == fwd_rs2);
                branch_target = id_ex.pc + id_ex.imm;
            end
            7'b1101111: begin                              // JAL
                alu_result    = id_ex.pc + 4;
                branch_taken  = 1;
                branch_target = id_ex.pc + id_ex.imm;
            end
            default: ;
        endcase

        flush = branch_taken;
    end

    always_comb begin
        ex_mem_next.alu_result = alu_result;
        ex_mem_next.rs2_val    = fwd_rs2;
        ex_mem_next.rd         = id_ex.rd;
        ex_mem_next.opcode     = id_ex.opcode;
        ex_mem_next.valid      = id_ex.valid;
    end

    // ============================================================
    // MEM / WB
    // ============================================================

    typedef struct packed {
        word result;
        regname rd;
        logic reg_write;
        logic valid;
    } mem_wb_t;

    mem_wb_t mem_wb, mem_wb_next;

    always_comb begin
        data_mem_req.valid    = 0;
        data_mem_req.addr     = 0;
        data_mem_req.data     = 0;
        data_mem_req.do_read  = 0;
        data_mem_req.do_write = 0;

        mem_wb_next = 0;

        if (ex_mem.valid) begin
            case (ex_mem.opcode)
                7'b0000011: begin // LW
                    data_mem_req.valid   = 1;
                    data_mem_req.addr    = ex_mem.alu_result;
                    data_mem_req.do_read = 4'b1111;

                    mem_wb_next.result    = data_mem_rsp.data;
                    mem_wb_next.reg_write = 1;
                end
                7'b0100011: begin // SW
                    data_mem_req.valid    = 1;
                    data_mem_req.addr     = ex_mem.alu_result;
                    data_mem_req.data     = ex_mem.rs2_val;
                    data_mem_req.do_write = 4'b1111;
                end
                default: begin
                    mem_wb_next.result    = ex_mem.alu_result;
                    mem_wb_next.reg_write = 1;
                end
            endcase

            mem_wb_next.rd    = ex_mem.rd;
            mem_wb_next.valid = ex_mem.valid;
        end
    end

    // ============================================================
    // PIPELINE REGISTERS
    // ============================================================

    always_ff @(posedge clk) begin
        if (reset) begin
            if_id  <= 0;
            id_ex  <= 0;
            ex_mem <= 0;
            mem_wb <= 0;
        end else begin
            if_id  <= if_id_next;
            id_ex  <= id_ex_next;
            ex_mem <= ex_mem_next;
            mem_wb <= mem_wb_next;
        end
    end

    // ============================================================
    // WRITEBACK
    // ============================================================

    always_ff @(posedge clk) begin
        if (mem_wb.valid && mem_wb.reg_write && mem_wb.rd != 0)
            regfile[mem_wb.rd] <= mem_wb.result;
    end

    // ============================================================
    // DEBUG OUTPUTS
    // ============================================================

    always_ff @(posedge clk) begin
        if (!reset)
            $display("[PC] pc=%08h  stall=%0d flush=%0d", pc, stall, flush);
    end

    always_ff @(posedge clk) begin
        if (!reset && data_mem_req.valid) begin
            if (data_mem_req.do_write != 0)
                $display("[MEM] STORE addr=%08h data=%08h",
                         data_mem_req.addr,
                         data_mem_req.data);
            if (data_mem_req.do_read != 0)
                $display("[MEM] LOAD  addr=%08h", data_mem_req.addr);
        end
    end

    always_ff @(posedge clk) begin
        if (!reset)
            $display("[REGS] x5=%08h x6=%08h x7=%08h",
                     regfile[5], regfile[6], regfile[7]);
    end

endmodule

`endif