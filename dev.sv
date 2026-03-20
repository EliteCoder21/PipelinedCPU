
`ifndef _core_v
`define _core_v
`include "system.sv"
`include "base.sv"
`include "memory_io.sv"
`include "memory.sv"

module core(
    input logic        clk
    ,input logic       reset
    ,input logic       [`word_address_size-1:0] reset_pc
    ,output memory_io_req   inst_mem_req
    ,input  memory_io_rsp   inst_mem_rsp
    ,output memory_io_req   data_mem_req
    ,input  memory_io_rsp   data_mem_rsp
);

`include "riscv32_common.sv"

// --- Pipeline Registers ---
typedef struct packed {
    word_address pc;
    instr32      instr;
    bool         valid;
} if_id_reg;

typedef struct packed {
    word_address pc;
    word         rd1, rd2, imm;
    tag          rs1, rs2, wbs;
    bool         wbv;
    opcode_q     op_q;
    funct3       f3;
    funct7       f7;
    bool         valid;
} id_ex_reg;

typedef struct packed {
    word         exec_result;
    word         rd2;
    tag          wbs;
    bool         wbv;
    opcode_q     op_q;
    funct3       f3;
    bool         valid;
} ex_mem_reg;

typedef struct packed {
    word         wbd;
    tag          wbs;
    bool         wbv;
    bool         valid;
} mem_wb_reg;

if_id_reg  if_id;
id_ex_reg  id_ex;
ex_mem_reg ex_mem;
mem_wb_reg mem_wb;

word reg_file[0:31];
word_address pc;

// --- Control Signals ---
logic stall, flush;
logic branch_taken;
word  branch_target;
word  forward_a, forward_b;

// --- 1. Forwarding Unit (EX Stage) ---
// This prevents the "fffffffc" error by ensuring 'addi' sees the 'lui' result immediately.
always_comb begin
    forward_a = id_ex.rd1;
    forward_b = id_ex.rd2;

    // Forward from MEM stage result
    if (ex_mem.valid && ex_mem.wbv && ex_mem.wbs != 0) begin
        if (ex_mem.wbs == id_ex.rs1) forward_a = ex_mem.exec_result;
        if (ex_mem.wbs == id_ex.rs2) forward_b = ex_mem.exec_result;
    end
    // Forward from WB stage result
    if (mem_wb.valid && mem_wb.wbv && mem_wb.wbs != 0) begin
        if (mem_wb.wbs == id_ex.rs1) forward_a = mem_wb.wbd;
        if (mem_wb.wbs == id_ex.rs2) forward_b = mem_wb.wbd;
    end
end

// --- 2. Hazard & Flow Control ---
assign flush = branch_taken; 
// Stall if memory isn't ready OR if we have a Load-Use hazard (simplified here as memory stall)
assign stall = (data_mem_req.valid && !data_mem_rsp.valid);

// --- STAGE 1: Fetch (IF) ---
assign inst_mem_req.addr = pc;
assign inst_mem_req.valid = !reset;
assign inst_mem_req.do_read = 4'b1111;

always_ff @(posedge clk) begin
    if (reset) begin
        pc <= reset_pc;
        if_id.valid <= false;
    end else if (!stall) begin
        if (flush) begin
            pc <= branch_target;
            if_id.valid <= false; // Kill instruction currently being fetched
        end else if (inst_mem_rsp.valid) begin
            pc <= pc + 4;
            if_id.pc <= pc;
            if_id.instr <= inst_mem_rsp.data;
            if_id.valid <= true;
        end else begin
            if_id.valid <= false; // Wait for memory to provide valid instruction
        end
    end
end

// --- STAGE 2: Decode (ID) ---
word raw_rd1, raw_rd2;
always_comb begin
    // INTERNAL FORWARDING: If WB is writing to a reg we are reading, bypass the reg_file
    raw_rd1 = (mem_wb.valid && mem_wb.wbv && mem_wb.wbs == decode_rs1(if_id.instr)) ? mem_wb.wbd : reg_file[decode_rs1(if_id.instr)];
    raw_rd2 = (mem_wb.valid && mem_wb.wbv && mem_wb.wbs == decode_rs2(if_id.instr)) ? mem_wb.wbd : reg_file[decode_rs2(if_id.instr)];
end

always_ff @(posedge clk) begin
    if (reset || flush) begin
        id_ex.valid <= false;
    end else if (!stall) begin
        id_ex.pc    <= if_id.pc;
        id_ex.rs1   <= decode_rs1(if_id.instr);
        id_ex.rs2   <= decode_rs2(if_id.instr);
        id_ex.rd1   <= (decode_rs1(if_id.instr) == 0) ? 0 : raw_rd1;
        id_ex.rd2   <= (decode_rs2(if_id.instr) == 0) ? 0 : raw_rd2;
        id_ex.imm   <= decode_imm(if_id.instr, decode_format(decode_opcode_q(if_id.instr)));
        id_ex.wbs   <= decode_rd(if_id.instr);
        id_ex.wbv   <= decode_writeback(decode_opcode_q(if_id.instr));
        id_ex.op_q  <= decode_opcode_q(if_id.instr);
        id_ex.f3    <= decode_funct3(if_id.instr);
        id_ex.f7    <= decode_funct7(if_id.instr, decode_format(decode_opcode_q(if_id.instr)));
        id_ex.valid <= if_id.valid;
    end
end

// --- STAGE 3: Execute (EX) ---
ext_operand ex_res_comb;
always_comb begin
    ex_res_comb = execute(cast_to_ext_operand(forward_a), 
                          cast_to_ext_operand(forward_b), 
                          cast_to_ext_operand(id_ex.imm), 
                          id_ex.pc, id_ex.op_q, id_ex.f3, id_ex.f7);

    branch_taken = id_ex.valid && (
        (id_ex.op_q == q_branch && ex_res_comb[0]) || 
        (id_ex.op_q == q_jal) || 
        (id_ex.op_q == q_jalr)
    );
    // Standard RISC-V: JAL/Branch use PC-relative offsets. JALR uses absolute.
    branch_target = (id_ex.op_q == q_jalr) ? (forward_a + id_ex.imm) & ~32'h1 : (id_ex.pc + id_ex.imm);
end

always_ff @(posedge clk) begin
    if (reset || flush) ex_mem.valid <= false;
    else if (!stall) begin
        // JAL/JALR need to write PC+4 to the destination register
        ex_mem.exec_result <= (id_ex.op_q == q_jal || id_ex.op_q == q_jalr) ? id_ex.pc + 4 : ex_res_comb[`word_size-1:0];
        ex_mem.rd2         <= forward_b;
        ex_mem.wbs         <= id_ex.wbs;
        ex_mem.wbv         <= id_ex.wbv;
        ex_mem.op_q        <= id_ex.op_q;
        ex_mem.f3          <= id_ex.f3;
        ex_mem.valid       <= id_ex.valid;
    end
end

// --- STAGE 4: Memory (MEM) ---
always_comb begin
    data_mem_req = memory_io_no_req32;
    if (ex_mem.valid && (ex_mem.op_q == q_store || ex_mem.op_q == q_load)) begin
        data_mem_req.addr = ex_mem.exec_result[`word_address_size - 1:0];
        data_mem_req.valid = true;
        if (ex_mem.op_q == q_store) begin
            data_mem_req.do_write = shuffle_store_mask(memory_mask(cast_to_memory_op(ex_mem.f3)), ex_mem.exec_result);
            data_mem_req.data     = shuffle_store_data(ex_mem.rd2, ex_mem.exec_result);
        end else begin
            data_mem_req.do_read = 4'b1111; 
        end
    end
end

always_ff @(posedge clk) begin
    if (reset) mem_wb.valid <= false;
    else if (!stall) begin
        if (ex_mem.op_q == q_load && data_mem_rsp.valid)
            mem_wb.wbd <= subset_load_data(shuffle_load_data(data_mem_rsp.data, ex_mem.exec_result), cast_to_memory_op(ex_mem.f3));
        else
            mem_wb.wbd <= ex_mem.exec_result;
            
        mem_wb.wbs   <= ex_mem.wbs;
        mem_wb.wbv   <= ex_mem.wbv;
        mem_wb.valid <= ex_mem.valid;
    end
end

// --- STAGE 5: Writeback (WB) ---
always_ff @(posedge clk) begin
    if (!reset && mem_wb.valid && mem_wb.wbv && mem_wb.wbs != 0) begin
        reg_file[mem_wb.wbs] <= mem_wb.wbd;
    end
end

// --- Debug Monitor ---
always @(posedge clk) begin
    if (!reset && !stall) begin
        $display("PC=%h t0=%h t1=%h t2=%h", if_id.pc, reg_file[5], reg_file[6], reg_file[7]);
        if (data_mem_req.valid)
            $display("    [Mem] Addr=%h Data=%h WriteMask=%b", data_mem_req.addr, data_mem_req.data, data_mem_req.do_write);
    end
end

endmodule
`endif