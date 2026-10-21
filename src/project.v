/*
 * Copyright (c) 2026 Adnan Saad
 * SPDX-License-Identifier: Apache-2.0
 */

/* BYTE2: a BYTEM3 CPU with a multiplexed external 64 KB memory interface.
 * memory map:
 * 16'h0000-16'h7FFF : 32 KB ROM
 * 16'h8000-16'hFFFF : 32 KB RAM
 * external bus protocol on uo_out:
 *   8'hA1 = address high byte phase; cpu drives uio = address[15:8]
 *   8'hA2 = address low byte phase;  cpu drives uio = address[7:0]
 *   8'hA3 = read phase;             controller drives uio with memory byte
 *   8'hA4 = write phase;            cpu drives uio with write byte
 *   8'hFF = idle / no transaction
 * ui_in[0] is a level handshake:
 *   ready starts high. controller detects new phase and drives ready low.
 *   cpu waits for low, then waits for high before advancing
 * other ui_in bits are reserved
 * uio_oe is output-enable bus
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

    localparam [7:0]
        PH_IDLE     = 8'hFF,
        PH_ADDR_HI  = 8'hA1,
        PH_ADDR_LO  = 8'hA2,
        PH_READ     = 8'hA3,
        PH_WRITE    = 8'hA4;

    localparam [2:0]
        S_FETCH_START = 3'd0,
        S_EXEC        = 3'd1,
        S_BUS_REQ     = 3'd2,
        S_BUS_WAIT    = 3'd3,
        S_HALT        = 3'd4;

    localparam [1:0]
        K_FETCH_LO = 2'd0,
        K_FETCH_HI = 2'd1,
        K_LOAD     = 2'd2,
        K_STORE    = 2'd3;

    reg [2:0] state;
    reg [15:0] regs [1:14];
    reg [15:0] pc;
    reg [15:0] ir;
    reg [7:0] fetch_lo;

    reg [1:0] pending_kind;
    reg [3:0] pending_rd;
    reg [15:0] pending_addr;
    reg [7:0] pending_wdata;
    reg pending_is_store;
    reg [1:0] bus_step;

    reg [3:0] flags; // V=3, C=2, N=1, Z=0

    reg [7:0] phase_r;
    reg [7:0] data_out_r;
    reg [7:0] data_oe_r;

    assign uo_out  = phase_r;
    assign uio_out = data_out_r;
    assign uio_oe  = data_oe_r;

    wire mem_ready = ui_in[0];

    function [15:0] reg_value;
        input [3:0] index;
        begin
            if (index == 4'd0)
                reg_value = 16'h0000;
            else if (index == 4'd15)
                reg_value = pc;
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
                pc <= value;
        end
    endtask

    function [15:0] effective_addr;
        input [15:0] value;
        begin
            effective_addr = value;
        end
    endfunction

    integer i;
    reg [3:0] op, rd, ra, rb;
    reg [15:0] va, vb, result;
    reg [16:0] wide_result;
    reg signed_overflow;
    reg [7:0] short_target;
    
    always @* begin
        phase_r   = PH_IDLE;
        data_out_r = 8'h00;
        data_oe_r  = 8'h00;

        if (state == S_BUS_REQ || state == S_BUS_WAIT) begin
            case (bus_step)
                2'd0: begin
                    phase_r    = PH_ADDR_HI;
                    data_out_r = pending_addr[15:8];
                    data_oe_r  = 8'hFF;
                end
                2'd1: begin
                    phase_r    = PH_ADDR_LO;
                    data_out_r = pending_addr[7:0];
                    data_oe_r  = 8'hFF;
                end
                2'd2: begin
                    if (pending_is_store) begin
                        phase_r    = PH_WRITE;
                        data_out_r = pending_wdata;
                        data_oe_r  = 8'hFF;
                    end else begin
                        phase_r    = PH_READ;
                        data_out_r = 8'h00;
                        data_oe_r  = 8'h00;
                    end
                end
                default: begin
                    phase_r    = PH_IDLE;
                    data_out_r = 8'h00;
                    data_oe_r  = 8'h00;
                end
            endcase
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state            <= S_FETCH_START;
            pc               <= 16'h0000;
            ir               <= 16'h0000;
            fetch_lo         <= 8'h00;
            pending_kind     <= K_FETCH_LO;
            pending_rd       <= 4'h0;
            pending_addr     <= 16'h0000;
            pending_wdata    <= 8'h00;
            pending_is_store <= 1'b0;
            bus_step         <= 2'd0;
            flags            <= 4'b0001;
            for (i = 1; i <= 14; i = i + 1)
                regs[i] <= 16'h0000;
        end else begin
            case (state)
                S_FETCH_START: begin
                    pending_addr     <= pc;
                    pending_kind     <= K_FETCH_LO;
                    pending_is_store <= 1'b0;
                    bus_step         <= 2'd0;
                    state            <= S_BUS_REQ;
                end
                S_BUS_REQ: begin
                    if (!mem_ready)
                        state <= S_BUS_WAIT;
                end

                S_BUS_WAIT: begin
                    if (mem_ready) begin
                        if (bus_step == 2'd0) begin
                            bus_step <= 2'd1;
                            state <= S_BUS_REQ;
                        end else if (bus_step == 2'd1) begin
                            bus_step <= 2'd2;
                            state <= S_BUS_REQ;
                        end else begin
                            case (pending_kind)
                                K_FETCH_LO: begin
                                    fetch_lo         <= uio_in;
                                    pending_addr     <= pc + 16'd1;
                                    pending_kind     <= K_FETCH_HI;
                                    pending_is_store <= 1'b0;
                                    bus_step         <= 2'd0;
                                    state            <= S_BUS_REQ;
                                end

                                K_FETCH_HI: begin
                                    ir    <= {uio_in, fetch_lo};
                                    pc    <= pc + 16'd2;
                                    state <= S_EXEC;
                                end

                                K_LOAD: begin
                                    write_reg(pending_rd, {8'h00, uio_in});
                                    state <= S_FETCH_START;
                                end

                                K_STORE: begin
                                    state <= S_FETCH_START;
                                end

                                default: state <= S_HALT;
                            endcase
                        end
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
                    short_target = ir[11:4];

                    case (op)
                        OP_AND: begin
                            result = va & vb;
                            write_reg(rd, result);
                            flags[0] <= (result == 16'h0000);
                            flags[1] <= result[15];
                            state <= S_FETCH_START;
                        end
                        OP_OR: begin
                            result = va | vb;
                            write_reg(rd, result);
                            flags[0] <= (result == 16'h0000);
                            flags[1] <= result[15];
                            state <= S_FETCH_START;
                        end
                        OP_XOR: begin
                            result = va ^ vb;
                            write_reg(rd, result);
                            flags[0] <= (result == 16'h0000);
                            flags[1] <= result[15];
                            state <= S_FETCH_START;
                        end
                        OP_NOT: begin
                            result = ~va;
                            write_reg(rd, result);
                            flags[0] <= (result == 16'h0000);
                            flags[1] <= result[15];
                            state <= S_FETCH_START;
                        end
                        OP_ADD: begin
                            wide_result = {1'b0, va} + {1'b0, vb};
                            result = wide_result[15:0];
                            signed_overflow = (~(va[15] ^ vb[15])) &
                                              (result[15] ^ va[15]);
                            write_reg(rd, result);
                            flags[0] <= (result == 16'h0000);
                            flags[1] <= result[15];
                            flags[2] <= wide_result[16];
                            flags[3] <= signed_overflow;
                            state <= S_FETCH_START;
                        end
                        OP_SUB: begin
                            wide_result = {1'b0, va} - {1'b0, vb};
                            result = va - vb;
                            signed_overflow = (va[15] ^ vb[15]) &
                                              (result[15] ^ va[15]);
                            write_reg(rd, result);
                            flags[0] <= (result == 16'h0000);
                            flags[1] <= result[15];
                            flags[2] <= (va >= vb);
                            flags[3] <= signed_overflow;
                            state <= S_FETCH_START;
                        end
                        OP_MOV: begin
                            result = vb;
                            write_reg(rd, result);
                            state <= S_FETCH_START;
                        end
                        OP_LDI: begin
                            result = {8'h00, ir[7:0]};
                            write_reg(rd, result);
                            state <= S_FETCH_START;
                        end
                        OP_LD: begin
                            pending_kind     <= K_LOAD;
                            pending_rd       <= rd;
                            pending_addr     <= effective_addr(va);
                            pending_wdata    <= 8'h00;
                            pending_is_store <= 1'b0;
                            bus_step         <= 2'd0;
                            state            <= S_BUS_REQ;
                        end
                        OP_ST: begin
                            pending_kind     <= K_STORE;
                            pending_rd       <= rd;
                            pending_addr     <= effective_addr(va);
                            pending_wdata    <= vb[7:0];
                            pending_is_store <= 1'b1;
                            bus_step         <= 2'd0;
                            state            <= S_BUS_REQ;
                        end
                        OP_JMP: begin
                            pc <= {8'h00, short_target};
                            state <= S_FETCH_START;
                        end
                        OP_JZ: begin
                            if (flags[0])
                                pc <= {8'h00, short_target};
                            state <= S_FETCH_START;
                        end
                        OP_JNZ: begin
                            if (!flags[0])
                                pc <= {8'h00, short_target};
                            state <= S_FETCH_START;
                        end
                        OP_SHL: begin
                            result = va << 1;
                            write_reg(rd, result);
                            flags[0] <= (result == 16'h0000);
                            flags[1] <= result[15];
                            flags[2] <= va[15];
                            state <= S_FETCH_START;
                        end
                        OP_SHR: begin
                            result = va >> 1;
                            write_reg(rd, result);
                            flags[0] <= (result == 16'h0000);
                            flags[1] <= result[15];
                            flags[2] <= va[0];
                            state <= S_FETCH_START;
                        end
                        OP_HLT: state <= S_HALT;
                        default: state <= S_HALT;
                    endcase
                end

                S_HALT: state <= S_HALT;
                default: state <= S_HALT;
            endcase
        end
    end

endmodule
