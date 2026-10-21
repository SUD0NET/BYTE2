/*
 * Copyright (c) 2026 Adnan Saad
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_byte2 (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ena,
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe
);

    localparam [3:0]
        OP_AND = 4'h0, OP_OR  = 4'h1, OP_XOR = 4'h2, OP_NOT = 4'h3,
        OP_ADD = 4'h4, OP_SUB = 4'h5, OP_MOV = 4'h6, OP_LDI = 4'h7,
        OP_LD  = 4'h8, OP_ST  = 4'h9, OP_JMP = 4'hA, OP_JZ  = 4'hB,
        OP_JNZ = 4'hC, OP_SHL = 4'hD, OP_SHR = 4'hE, OP_HLT = 4'hF;

    localparam [2:0]
        S_FETCH_LO_REQ = 3'd0,
        S_FETCH_LO_WAIT= 3'd1,
        S_FETCH_HI_REQ = 3'd2,
        S_FETCH_HI_WAIT= 3'd3,
        S_EXEC         = 3'd4,
        S_MEM_REQ      = 3'd5,
        S_MEM_WAIT     = 3'd6,
        S_HALT         = 3'd7;

    reg [2:0] state;
    reg [15:0] regs [1:14];
    reg [7:0] pc;
    reg [15:0] ir;
    reg [7:0] fetch_lo;
    reg [3:0] pending_op;
    reg [3:0] pending_rd;
    reg [7:0] pending_addr;
    reg [7:0] pending_wdata;
    reg pending_is_store;
    reg [3:0] flags; // V=3, C=2, N=1, Z=0

    reg [7:0] addr_r;
    reg [7:0] data_out_r;
    reg [7:0] data_oe_r;

    assign uo_out  = addr_r;
    assign uio_out = data_out_r;
    assign uio_oe  = data_oe_r;

    wire mem_ready = ui_in[0];

    function [15:0] reg_value;
        input [3:0] index;
        begin
            if (index == 4'd0)
                reg_value = 16'h0000;
            else if (index == 4'd15)
                reg_value = {8'h00, pc};
            else
                reg_value = regs[index];
        end
    endfunction

    task write_reg;
        input [3:0] index;
        input [15:0] value;
        begin
            if (index >= 4'd1 && index <= 4'd14)
                regs[index] <= value;
            else if (index == 4'd15)
                pc <= value[7:0];
        end
    endtask

    function [7:0] effective_addr;
        input [15:0] value;
        begin
            effective_addr = value[7:0];
        end
    endfunction

    integer i;
    reg [3:0] op, rd, ra, rb;
    reg [15:0] va, vb, result;
    reg [16:0] wide_result;
    reg signed_overflow;
    reg [7:0] target;
    reg [7:0] next_pc;

    always @* begin
        // idle defaults
        addr_r     = 8'hFF;
        data_out_r = 8'h00;
        data_oe_r  = 8'h00;
        if (state == S_FETCH_LO_REQ || state == S_FETCH_LO_WAIT) begin
            addr_r = pc;
        end else if (state == S_FETCH_HI_REQ || state == S_FETCH_HI_WAIT) begin
            addr_r = pc + 8'd1;
        end else if (state == S_MEM_REQ || state == S_MEM_WAIT) begin
            addr_r = pending_addr;
            if (pending_is_store) begin
                data_out_r = pending_wdata;
                data_oe_r  = 8'hFF;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_FETCH_LO_REQ;
            pc <= 8'h00;
            ir <= 16'h0000;
            fetch_lo <= 8'h00;
            pending_op <= 4'h0;
            pending_rd <= 4'h0;
            pending_addr <= 8'h00;
            pending_wdata <= 8'h00;
            pending_is_store <= 1'b0;
            flags <= 4'b0001;
            for (i = 1; i <= 14; i = i + 1)
                regs[i] <= 16'h0000;
        end else begin
            case (state)
                S_FETCH_LO_REQ: begin
                    if (mem_ready)
                        state <= S_FETCH_LO_WAIT;
                end
                S_FETCH_LO_WAIT: begin
                    // return byte in memory when mem_ready is HIGH
                    if (mem_ready) begin
                        fetch_lo <= uio_in;
                        state <= S_FETCH_HI_REQ;
                    end
                end
                S_FETCH_HI_REQ: begin
                    if (mem_ready)
                        state <= S_FETCH_HI_WAIT;
                end
                S_FETCH_HI_WAIT: begin
                    if (mem_ready) begin
                      ir <= {uio_in, fetch_lo}; // little-endian
                        pc <= pc + 8'd2;
                        state <= S_EXEC;
                    end
                end
                S_EXEC: begin
                    op = ir[15:12];
                    rd = ir[11:8];
                    ra = ir[7:4];
                    rb = ir[3:0];
                    va = reg_value(ra);
                    vb = reg_value(rb);
                    result = 16'h0000;
                    wide_result = 17'h00000;
                    signed_overflow = 1'b0;
                    next_pc = pc;
                    target = ir[11:4];

                    case (op)
                        OP_AND: begin
                            result = va & vb;
                            write_reg(rd, result);
                            flags[0] <= (result == 16'h0000);
                            flags[1] <= result[15];
                            state <= S_FETCH_LO_REQ;
                        end
                        OP_OR: begin
                            result = va | vb;
                            write_reg(rd, result);
                            flags[0] <= (result == 16'h0000);
                            flags[1] <= result[15];
                            state <= S_FETCH_LO_REQ;
                        end
                        OP_XOR: begin
                            result = va ^ vb;
                            write_reg(rd, result);
                            flags[0] <= (result == 16'h0000);
                            flags[1] <= result[15];
                            state <= S_FETCH_LO_REQ;
                        end
                        OP_NOT: begin
                            result = ~va;
                            write_reg(rd, result);
                            flags[0] <= (result == 16'h0000);
                            flags[1] <= result[15];
                            state <= S_FETCH_LO_REQ;
                        end
                        OP_ADD: begin
                            wide_result = {1'b0, va} + {1'b0, vb};
                            result = wide_result[15:0];
                            signed_overflow = (~(va[15] ^ vb[15])) & (result[15] ^ va[15]);
                            write_reg(rd, result);
                            flags[0] <= (result == 16'h0000);
                            flags[1] <= result[15];
                            flags[2] <= wide_result[16];
                            flags[3] <= signed_overflow;
                            state <= S_FETCH_LO_REQ;
                        end
                        OP_SUB: begin
                            wide_result = {1'b0, va} - {1'b0, vb};
                            result = va - vb;
                            signed_overflow = (va[15] ^ vb[15]) & (result[15] ^ va[15]);
                            write_reg(rd, result);
                            flags[0] <= (result == 16'h0000);
                            flags[1] <= result[15];
                            flags[2] <= (va >= vb); // C=1 means no borrow
                            flags[3] <= signed_overflow;
                            state <= S_FETCH_LO_REQ;
                        end
                        OP_MOV: begin
                            result = vb;
                            write_reg(rd, result);
                            state <= S_FETCH_LO_REQ;
                        end
                        OP_LDI: begin
                            result = {8'h00, ir[7:0]};
                            write_reg(rd, result);
                            state <= S_FETCH_LO_REQ;
                        end
                        OP_LD: begin
                            pending_op <= OP_LD;
                            pending_rd <= rd;
                            pending_addr <= effective_addr(va);
                            pending_is_store <= 1'b0;
                            state <= S_MEM_REQ;
                        end
                        OP_ST: begin
                            pending_op <= OP_ST;
                            pending_rd <= rd;
                            pending_addr <= effective_addr(va);
                            pending_wdata <= vb[7:0];
                            pending_is_store <= 1'b1;
                            state <= S_MEM_REQ;
                        end
                        OP_JMP: begin
                            pc <= target;
                            state <= S_FETCH_LO_REQ;
                        end
                        OP_JZ: begin
                            if (flags[0]) pc <= target;
                            state <= S_FETCH_LO_REQ;
                        end
                        OP_JNZ: begin
                            if (!flags[0]) pc <= target;
                            state <= S_FETCH_LO_REQ;
                        end
                        OP_SHL: begin
                            result = va << 1;
                            write_reg(rd, result);
                            flags[0] <= (result == 16'h0000);
                            flags[1] <= result[15];
                            flags[2] <= va[15];
                            state <= S_FETCH_LO_REQ;
                        end
                        OP_SHR: begin
                            result = va >> 1;
                            write_reg(rd, result);
                            flags[0] <= (result == 16'h0000);
                            flags[1] <= result[15];
                            flags[2] <= va[0];
                            state <= S_FETCH_LO_REQ;
                        end
                        OP_HLT: state <= S_HALT;
                        default: state <= S_HALT;
                    endcase
                end
                S_MEM_REQ: begin
                    if (mem_ready)
                        state <= S_MEM_WAIT;
                end
                S_MEM_WAIT: begin
                    if (mem_ready) begin
                        if (!pending_is_store)
                            write_reg(pending_rd, {8'h00, uio_in});
                        state <= S_FETCH_LO_REQ;
                    end
                end
                S_HALT: state <= S_HALT;
                default: state <= S_HALT;
            endcase
        end
    end

endmodule
