// UPduino 3.1 - iCE40 UP5K Maximum Observability Experiment
//
// Instantiates every major UP5K hard primitive and routes internal
// signals to GPIO pins for probing.  No external clock required —
// uses the on-chip 48 MHz HFOSC and 10 kHz LFOSC.
//
// Primitives exercised:
//   SB_HFOSC        — 48 MHz high-frequency oscillator (÷8 = 6 MHz)
//   SB_LFOSC        — 10 kHz low-frequency oscillator
//   SB_RGBA_DRV     — RGB LED driver (visual heartbeat)
//   SB_SPRAM256KA   — 256Kbit single-port RAM (write/read test pattern)
//   SB_MAC16        — 16×16 DSP multiply-accumulate
//   SB_IO           — registered I/O (on observable outputs)

module top (
    // RGB LED (active via hard driver, active active directly)
    output RGB0,
    output RGB1,
    output RGB2,

    // Observable GPIO — directly active active probe points
    output HCLK_DIV,       // divided HFOSC heartbeat
    output LCLK_OUT,       // raw LFOSC output

    output FSM0,           // state machine bits
    output FSM1,
    output FSM2,

    output SPRAM_D0,       // SPRAM readback
    output SPRAM_D1,
    output SPRAM_D2,
    output SPRAM_D3,

    output DSP_D0,         // MAC16 result
    output DSP_D1,
    output DSP_D2,
    output DSP_D3,

    output CTR0,           // free-running counter
    output CTR1,
    output CTR2,
    output CTR3,
    output CTR4
);

// ---------------------------------------------------------------
// 1. CLOCKS
// ---------------------------------------------------------------

// 48 MHz high-frequency oscillator, divided by 8 → 6 MHz
wire hf_clk;
SB_HFOSC #(
    .CLKHF_DIV ("0b10")      // 00=48, 01=24, 10=12, 11=6 MHz
) u_hfosc (
    .CLKHFPU (1'b1),
    .CLKHFEN (1'b1),
    .CLKHF   (hf_clk)
);

// 10 kHz low-frequency oscillator
wire lf_clk;
SB_LFOSC u_lfosc (
    .CLKLFPU (1'b1),
    .CLKLFEN (1'b1),
    .CLKLF   (lf_clk)
);

// ---------------------------------------------------------------
// 2. FREE-RUNNING COUNTER  (main timebase / divider)
// ---------------------------------------------------------------
reg [31:0] ctr = 0;
always @(posedge hf_clk)
    ctr <= ctr + 1;

// Expose counter bits at different rates for scope triggering
assign HCLK_DIV = ctr[22];   // ~2.86 Hz visible blink at 12 MHz
assign CTR0     = ctr[0];    // 6 MHz   (fastest toggling)
assign CTR1     = ctr[4];    // 375 kHz
assign CTR2     = ctr[8];    // ~23 kHz
assign CTR3     = ctr[16];   // ~91 Hz
assign CTR4     = ctr[20];   // ~5.7 Hz

// LFOSC direct output
reg lf_toggle = 0;
always @(posedge lf_clk)
    lf_toggle <= ~lf_toggle;
assign LCLK_OUT = lf_toggle; // ~5 kHz toggle

// ---------------------------------------------------------------
// 3. STATE MACHINE  (exercises SPRAM + DSP sequentially)
// ---------------------------------------------------------------
localparam S_IDLE       = 3'd0;
localparam S_SPRAM_WR   = 3'd1;
localparam S_SPRAM_RD   = 3'd2;
localparam S_DSP_LOAD   = 3'd3;
localparam S_DSP_READ   = 3'd4;
localparam S_DONE       = 3'd5;

reg [2:0]  state = S_IDLE;
reg [7:0]  step  = 0;         // sub-step counter

assign FSM0 = state[0];
assign FSM1 = state[1];
assign FSM2 = state[2];

// ---------------------------------------------------------------
// 4. SPRAM  (256Kbit single-port RAM)
// ---------------------------------------------------------------
reg  [13:0] sp_addr  = 0;
reg  [15:0] sp_wdata = 0;
reg         sp_wen   = 0;
reg  [3:0]  sp_maskwen = 4'b1111;
wire [15:0] sp_rdata;

SB_SPRAM256KA u_spram (
    .ADDRESS    (sp_addr),
    .DATAIN     (sp_wdata),
    .MASKWREN   (sp_maskwen),
    .WREN       (sp_wen),
    .CHIPSELECT (1'b1),
    .CLOCK      (hf_clk),
    .STANDBY    (1'b0),
    .SLEEP      (1'b0),
    .POWEROFF   (1'b1),       // active low — 1 = powered on
    .DATAOUT    (sp_rdata)
);

assign SPRAM_D0 = sp_rdata[0];
assign SPRAM_D1 = sp_rdata[1];
assign SPRAM_D2 = sp_rdata[2];
assign SPRAM_D3 = sp_rdata[3];

// ---------------------------------------------------------------
// 5. DSP / MAC16  (16×16 multiply)
// ---------------------------------------------------------------
reg  [15:0] dsp_a = 0;
reg  [15:0] dsp_b = 0;
wire [31:0] dsp_o;

SB_MAC16 #(
    .NEG_TRIGGER            (1'b0),
    .C_REG                  (1'b0),
    .A_REG                  (1'b1),
    .B_REG                  (1'b1),
    .D_REG                  (1'b0),
    .TOP_8x8_MULT_REG      (1'b1),
    .BOT_8x8_MULT_REG      (1'b1),
    .PIPELINE_16x16_MULT_REG1 (1'b1),
    .PIPELINE_16x16_MULT_REG2 (1'b0),
    .TOPOUTPUT_SELECT       (2'b11),   // 16x16 multiply upper
    .TOPADDSUB_LOWERINPUT   (2'b00),
    .TOPADDSUB_UPPERINPUT   (1'b0),
    .TOPADDSUB_CARRYSELECT  (2'b00),
    .BOTOUTPUT_SELECT       (2'b11),   // 16x16 multiply lower
    .BOTADDSUB_LOWERINPUT   (2'b00),
    .BOTADDSUB_UPPERINPUT   (1'b0),
    .BOTADDSUB_CARRYSELECT  (2'b00),
    .MODE_8x8               (1'b0),
    .A_SIGNED               (1'b0),
    .B_SIGNED               (1'b0)
) u_mac16 (
    .CLK        (hf_clk),
    .CE         (1'b1),
    .A          (dsp_a),
    .B          (dsp_b),
    .C          (16'b0),
    .D          (16'b0),
    .AHOLD      (1'b0),
    .BHOLD      (1'b0),
    .CHOLD      (1'b0),
    .DHOLD      (1'b0),
    .IRSTTOP    (1'b0),
    .IRSTBOT    (1'b0),
    .ORSTTOP    (1'b0),
    .ORSTBOT    (1'b0),
    .OLOADTOP   (1'b0),
    .OLOADBOT   (1'b0),
    .ADDSUBTOP  (1'b0),
    .ADDSUBBOT  (1'b0),
    .OHOLDTOP   (1'b0),
    .OHOLDBOT   (1'b0),
    .CI         (1'b0),
    .ACCUMCI    (1'b0),
    .SIGNEXTIN  (1'b0),
    .O          (dsp_o)
);

assign DSP_D0 = dsp_o[0];
assign DSP_D1 = dsp_o[1];
assign DSP_D2 = dsp_o[2];
assign DSP_D3 = dsp_o[3];

// ---------------------------------------------------------------
// 6. SEQUENCER  (drives SPRAM + DSP through test patterns)
// ---------------------------------------------------------------
always @(posedge hf_clk) begin
    // defaults
    sp_wen <= 1'b0;

    case (state)
        S_IDLE: begin
            step <= 0;
            state <= S_SPRAM_WR;
        end

        // Write ascending pattern into SPRAM addresses 0..15
        S_SPRAM_WR: begin
            sp_addr  <= {10'b0, step[3:0]};
            sp_wdata <= {8'hA0, step};
            sp_wen   <= 1'b1;
            if (step == 8'd15) begin
                step  <= 0;
                state <= S_SPRAM_RD;
            end else
                step <= step + 1;
        end

        // Read back SPRAM addresses 0..15 (data appears on SPRAM_Dx)
        S_SPRAM_RD: begin
            sp_addr <= {10'b0, step[3:0]};
            if (step == 8'd15) begin
                step  <= 0;
                state <= S_DSP_LOAD;
            end else
                step <= step + 1;
        end

        // Feed incrementing values into DSP multiply
        S_DSP_LOAD: begin
            dsp_a <= {8'b0, step};
            dsp_b <= {8'b0, step};
            state <= S_DSP_READ;
        end

        // Let pipeline flush, result visible on DSP_Dx
        S_DSP_READ: begin
            if (step == 8'd255)
                state <= S_DONE;
            else begin
                step  <= step + 1;
                state <= S_DSP_LOAD;
            end
        end

        // Loop forever — restart
        S_DONE: begin
            step  <= 0;
            state <= S_IDLE;
        end

        default: state <= S_IDLE;
    endcase
end

// ---------------------------------------------------------------
// 7. RGB LED DRIVER  (visual heartbeat — cycles R→G→B)
// ---------------------------------------------------------------
wire [1:0] rgb_phase = ctr[25:24]; // ~0.7 s per phase at 12 MHz

wire pwm_r = (rgb_phase == 2'd0);
wire pwm_g = (rgb_phase == 2'd1);
wire pwm_b = (rgb_phase == 2'd2);

SB_RGBA_DRV #(
    .CURRENT_MODE ("0b1"),          // half current mode
    .RGB0_CURRENT ("0b000111"),     // ~4 mA
    .RGB1_CURRENT ("0b000111"),
    .RGB2_CURRENT ("0b000111")
) u_rgba (
    .CURREN   (1'b1),
    .RGBLEDEN (1'b1),
    .RGB0PWM  (pwm_g),
    .RGB1PWM  (pwm_b),
    .RGB2PWM  (pwm_r),
    .RGB0     (RGB0),
    .RGB1     (RGB1),
    .RGB2     (RGB2)
);

endmodule
