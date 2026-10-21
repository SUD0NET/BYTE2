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
        S_FETCH_LO_REQ  = 3'd0,
        S_FETCH_LO_WAIT = 3'd1,
        S_FETCH_HI_REQ  = 3'd2,
        S_FETCH_HI_WAIT = 3'd3,
        S_EXEC          = 3'd4,
        S_MEM_REQ       = 3'd5,
        S_MEM_WAIT      = 3'd6,
        S_HALT          = 3'd7;

    reg  [2:0] state;
    reg  [7:0] pc;
    reg  [15:0] ir;
    reg  [3:0] flags;

    wire mem_ready = ui_in[0];

    reg  [55:0] regfile;
    wire [7:0]  rv [0:15];

    assign rv[0]  = 8'h00;
    assign rv[8]  = 8'h00;
    assign rv[9]  = 8'h00;
    assign rv[10] = 8'h00;
    assign rv[11] = 8'h00;
    assign rv[12] = 8'h00;
    assign rv[13] = 8'h00;
    assign rv[14] = 8'h00;
    assign rv[15] = pc;

    reg        wr_en;
    reg  [3:0] wr_idx;
    reg  [7:0] wr_data;

    genvar g;
    generate
        for (g = 1; g <= 7; g = g + 1) begin : g_reg
            assign rv[g] = regfile[(g-1)*8 +: 8];
            always @(posedge clk) begin
                if (!rst_n)
                    regfile[(g-1)*8 +: 8] <= 8'h00;
                else if (wr_en && (wr_idx == g[3:0]))
                    regfile[(g-1)*8 +: 8] <= wr_data;
            end
        end
    endgenerate

    wire [3:0] op     = ir[15:12];
    wire [3:0] rd     = ir[11:8];
    wire [3:0] ra     = ir[7:4];
    wire [3:0] rb     = ir[3:0];
    wire [7:0] target = ir[11:4];
    wire [7:0] va     = rv[ra];
    wire [7:0] vb     = rv[rb];

    reg [7:0] addr_r;
    reg [7:0] data_out_r;
    reg [7:0] data_oe_r;

    assign uo_out  = addr_r;
    assign uio_out = data_out_r;
    assign uio_oe  = data_oe_r;

    always @* begin
        addr_r     = 8'hFF;
        data_out_r = 8'h00;
        data_oe_r  = 8'h00;
        case (state)
            S_FETCH_LO_REQ,
            S_FETCH_LO_WAIT: addr_r = pc;
            S_FETCH_HI_REQ,
            S_FETCH_HI_WAIT: addr_r = pc + 8'd1;
            S_MEM_REQ,
            S_MEM_WAIT: begin
                addr_r = va;
                if (op == OP_ST) begin
                    data_out_r = vb;
                    data_oe_r  = 8'hFF;
                end
            end
            default: ;
        endcase
    end

    reg [2:0] state_next;
    reg [7:0] pc_next;
    reg [7:0] result;
    reg [8:0] wide_result;
    reg       upd_zn, upd_c, upd_v;
    reg       c_new, v_new;

    always @* begin
        state_next  = state;
        pc_next     = pc;
        result      = 8'h00;
        wide_result = 9'h000;
        upd_zn      = 1'b0;
        upd_c       = 1'b0;
        upd_v       = 1'b0;
        c_new       = 1'b0;
        v_new       = 1'b0;
        wr_en       = 1'b0;
        wr_idx      = rd;
        wr_data     = 8'h00;

        case (state)
            S_FETCH_LO_REQ:  if (mem_ready) state_next = S_FETCH_LO_WAIT;
            S_FETCH_LO_WAIT: if (mem_ready) state_next = S_FETCH_HI_REQ;
            S_FETCH_HI_REQ:  if (mem_ready) state_next = S_FETCH_HI_WAIT;
            S_FETCH_HI_WAIT: if (mem_ready) begin
                pc_next    = pc + 8'd2;
                state_next = S_EXEC;
            end

            S_EXEC: begin
                state_next = S_FETCH_LO_REQ;
                case (op)
                    OP_AND: begin result = va & vb; wr_en = 1'b1; upd_zn = 1'b1; end
                    OP_OR:  begin result = va | vb; wr_en = 1'b1; upd_zn = 1'b1; end
                    OP_XOR: begin result = va ^ vb; wr_en = 1'b1; upd_zn = 1'b1; end
                    OP_NOT: begin result = ~va;     wr_en = 1'b1; upd_zn = 1'b1; end
                    OP_ADD: begin
                        wide_result = {1'b0, va} + {1'b0, vb};
                        result = wide_result[7:0];
                        wr_en  = 1'b1;
                        upd_zn = 1'b1;
                        upd_c  = 1'b1;
                        c_new  = wide_result[8];
                        upd_v  = 1'b1;
                        v_new  = (~(va[7] ^ vb[7])) & (result[7] ^ va[7]);
                    end
                    OP_SUB: begin
                        wide_result = {1'b0, va} - {1'b0, vb};
                        result = wide_result[7:0];
                        wr_en  = 1'b1;
                        upd_zn = 1'b1;
                        upd_c  = 1'b1;
                        c_new  = ~wide_result[8];
                        upd_v  = 1'b1;
                        v_new  = (va[7] ^ vb[7]) & (result[7] ^ va[7]);
                    end
                    OP_MOV: begin result = vb;    wr_en = 1'b1; end
                    OP_LDI: begin result = ir[7:0]; wr_en = 1'b1; end
                    OP_LD,
                    OP_ST:  state_next = S_MEM_REQ;
                    OP_JMP: pc_next = target;
                    OP_JZ:  if ( flags[0]) pc_next = target;
                    OP_JNZ: if (!flags[0]) pc_next = target;
                    OP_SHL: begin
                        result = {va[6:0], 1'b0};
                        wr_en  = 1'b1;
                        upd_zn = 1'b1;
                        upd_c  = 1'b1;
                        c_new  = va[7];
                    end
                    OP_SHR: begin
                        result = {1'b0, va[7:1]};
                        wr_en  = 1'b1;
                        upd_zn = 1'b1;
                        upd_c  = 1'b1;
                        c_new  = va[0];
                    end
                    default: state_next = S_HALT;
                endcase
                wr_data = result;
            end

            S_MEM_REQ: if (mem_ready) state_next = S_MEM_WAIT;
            S_MEM_WAIT: if (mem_ready) begin
                if (op == OP_LD) begin
                    wr_en   = 1'b1;
                    wr_data = uio_in;
                end
                state_next = S_FETCH_LO_REQ;
            end

            default: state_next = S_HALT;
        endcase

        if (wr_en && (wr_idx == 4'd15))
            pc_next = wr_data;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_FETCH_LO_REQ;
            pc    <= 8'h00;
            flags <= 4'b0001;
        end else begin
            state <= state_next;
            pc    <= pc_next;
            if (state == S_EXEC) begin
                if (upd_zn) begin
                    flags[0] <= (result == 8'h00);
                    flags[1] <= result[7];
                end
                if (upd_c) flags[2] <= c_new;
                if (upd_v) flags[3] <= v_new;
            end
        end
    end

    always @(posedge clk) begin
        if (state == S_FETCH_LO_WAIT && mem_ready)
            ir[7:0] <= uio_in;
        if (state == S_FETCH_HI_WAIT && mem_ready)
            ir[15:8] <= uio_in;
    end

    wire _unused = &{ena, ui_in[7:1], 1'b0};

endmodule

`default_nettype wire
