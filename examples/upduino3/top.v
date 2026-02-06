// ===================================================================
// UPduino 3.1 — Clock Cycle Mechanics Experiment
// iCE40 UP5K  ·  uwg30 package  ·  no external clock
//
// PURPOSE: Make every clock-domain concept physically observable.
//          Probe any pin with a scope or logic analyzer.
//
// CLOCK SOURCES
//   HFOSC  12 MHz  (internal, CLKHF_DIV="0b10")
//   LFOSC  10 kHz  (internal)
//
// WHAT YOU CAN SEE
//   Section 1 — True clock outputs via DDR I/O
//   Section 2 — Explicit ÷2 divider chain (4 stages)
//   Section 3 — 2-FF clock domain crossing, LFOSC → HFOSC
//   Section 4 — 4-stage pipeline shift register
//   Section 5 — Timing markers: one-shot pulse, tick, clock gating
//   Section 6 — RGB LED heartbeat (visual alive check)
//
// CYCLE COUNTS
//   Every register transition is annotated with its exact latency
//   relative to the clock edge that causes it.
// ===================================================================

module top (
    // RGB LED (directly active driven by SB_RGBA_DRV hard IP)
    output RGB0,
    output RGB1,
    output RGB2,

    // Section 1: true clock waveforms
    output CLK_HF,          // 12 MHz HFOSC reproduced on pin
    output CLK_LF,          // 10 kHz LFOSC reproduced on pin

    // Section 2: divider chain
    output DIV2,            //  6.000 MHz   (HFOSC ÷ 2)
    output DIV4,            //  3.000 MHz   (HFOSC ÷ 4)
    output DIV8,            //  1.500 MHz   (HFOSC ÷ 8)
    output DIV16,           //    750 kHz   (HFOSC ÷ 16)

    // Section 3: clock domain crossing
    output SYNC0,           // 1st synchronizer FF (may glitch — metastable)
    output SYNC1,           // 2nd synchronizer FF (safe to use)
    output CDC_EDGE,        // one HFOSC-cycle pulse on each LFOSC rising edge

    // Section 4: pipeline
    output PIPE0,           // stage 0 — injected data
    output PIPE1,           // stage 1 — 1 cycle later
    output PIPE2,           // stage 2 — 2 cycles later
    output PIPE3,           // stage 3 — 3 cycles later

    // Section 5: timing markers
    output PULSE,           // one-cycle-wide pulse every 16 HFOSC cycles
    output TICK,            // toggles every HFOSC cycle (= HFOSC ÷ 2)
    output GATE_EN,         // clock-gate enable: HIGH for 8 cycles, LOW for 8
    output GATED_D,         // data register updated ONLY when GATE_EN is HIGH
    output CYCLE_ID         // bit 0 of a 4-bit cycle ID counter
);


// ===================================================================
// CLOCK GENERATION
// ===================================================================

// --- 12 MHz high-frequency oscillator ---
// CLKHF_DIV: "0b00"=48 MHz, "0b01"=24, "0b10"=12, "0b11"=6
wire hf_clk;
SB_HFOSC #(
    .CLKHF_DIV ("0b10")
) u_hfosc (
    .CLKHFPU (1'b1),        // power up
    .CLKHFEN (1'b1),        // enable
    .CLKHF   (hf_clk)       // 12 MHz out → global clock net
);

// --- 10 kHz low-frequency oscillator ---
wire lf_clk;
SB_LFOSC u_lfosc (
    .CLKLFPU (1'b1),
    .CLKLFEN (1'b1),
    .CLKLF   (lf_clk)       // 10 kHz out → used for CDC experiment
);


// ===================================================================
// SECTION 1: TRUE CLOCK OUTPUTS  (DDR I/O trick)
//
// We cannot directly route a global clock net to a pin.  Instead we
// use the SB_IO DDR output mode:  launch '1' on the rising edge and
// '0' on the falling edge.  The result is a faithful reproduction of
// the clock waveform on the output pin.
//
//   hf_clk  ──┐  ┌──┐  ┌──┐  ┌──
//              └──┘  └──┘  └──┘
//   CLK_HF  ──┐  ┌──┐  ┌──┐  ┌──    (same, delayed by t_CO of I/O)
//              └──┘  └──┘  └──┘
//
// Latency: ~t_CO (I/O clock-to-output), typically 5-8 ns on UP5K.
// ===================================================================

SB_IO #(
    .PIN_TYPE (6'b01_0000)   // DDR output, no input
) u_clk_hf_out (
    .PACKAGE_PIN (CLK_HF),
    .OUTPUT_CLK  (hf_clk),
    .D_OUT_0     (1'b1),     // driven HIGH on rising edge
    .D_OUT_1     (1'b0)      // driven LOW on falling edge
);

SB_IO #(
    .PIN_TYPE (6'b01_0000)
) u_clk_lf_out (
    .PACKAGE_PIN (CLK_LF),
    .OUTPUT_CLK  (lf_clk),
    .D_OUT_0     (1'b1),
    .D_OUT_1     (1'b0)
);


// ===================================================================
// SECTION 2: DIVIDER CHAIN
//
// Four explicit flip-flops, each toggling on posedge of the previous
// stage's output.  This is NOT a ripple counter — each stage is
// independently clocked by HFOSC so the output transitions are
// phase-aligned to within routing skew.
//
// Implementation: single shift counter where each bit toggles at
// its own rate.  On scope you see:
//
//   hf_clk  ┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐   12 MHz
//   DIV2    ┌──┐┌──┐┌──┐┌──┐┌──┐┌──┐┌──┐┌──┐       6 MHz
//   DIV4    ┌────┐┌────┐┌────┐┌────┐┌────┐           3 MHz
//   DIV8    ┌────────┐┌────────┐┌────────┐           1.5 MHz
//   DIV16   ┌────────────────┐┌────────────────┐     750 kHz
//
// All transitions occur on the SAME rising edge of hf_clk.
// Latency: each output changes 1 t_CQ after the hf_clk rising edge.
// ===================================================================

reg [3:0] div = 4'b0;

// Cycle N:  div[0] toggles.
//           div[1] toggles when div[0] was 1 (i.e. on its falling edge).
//           div[2] toggles when div[1:0] == 2'b11.
//           div[3] toggles when div[2:0] == 3'b111.
always @(posedge hf_clk) begin
    div[0] <= ~div[0];
    div[1] <= div[1] ^ div[0];
    div[2] <= div[2] ^ (div[1] & div[0]);
    div[3] <= div[3] ^ (div[2] & div[1] & div[0]);
end

assign DIV2  = div[0];       // 12 MHz ÷ 2  =  6.000 MHz
assign DIV4  = div[1];       //          ÷ 4  =  3.000 MHz
assign DIV8  = div[2];       //          ÷ 8  =  1.500 MHz
assign DIV16 = div[3];       //          ÷ 16 =    750 kHz


// ===================================================================
// SECTION 3: CLOCK DOMAIN CROSSING  (LFOSC → HFOSC)
//
// Classic 2-FF synchronizer.  The LFOSC edge is asynchronous to HFOSC.
//
// Timing (HFOSC cycles, worst case):
//
//   LFOSC rising ──┤
//   cycle 0:  sync0 samples LFOSC (may go metastable)
//   cycle 1:  sync1 samples sync0 (metastability resolved with
//             probability > 1 – exp(–t_MET/τ), τ ≈ 40 ps on iCE40)
//   cycle 2:  edge detector compares sync1 vs sync1_prev
//             → CDC_EDGE goes HIGH for exactly 1 HFOSC cycle
//
// On scope:  SYNC0 may show runt pulses if you catch metastability.
//            SYNC1 will always be clean.
//            CDC_EDGE is a clean one-cycle pulse.
// ===================================================================

// LFOSC domain: generate a toggle signal (10 kHz → 5 kHz toggle)
reg lf_toggle = 1'b0;
always @(posedge lf_clk)
    lf_toggle <= ~lf_toggle;

// HFOSC domain: 2-FF synchronizer
reg sync0 = 1'b0;
reg sync1 = 1'b0;
reg sync1_prev = 1'b0;

always @(posedge hf_clk) begin
    sync0      <= lf_toggle;      // cycle 0: sample (metastable risk)
    sync1      <= sync0;          // cycle 1: resolve
    sync1_prev <= sync1;          // cycle 2: delay for edge detect
end

// Rising-edge detector: HIGH for exactly 1 HFOSC cycle per LFOSC edge
wire cdc_rising = sync1 & ~sync1_prev;

assign SYNC0    = sync0;
assign SYNC1    = sync1;
assign CDC_EDGE = cdc_rising;


// ===================================================================
// SECTION 4: PIPELINE REGISTER CHAIN
//
// 4-stage shift register clocked by HFOSC.  A new data bit is
// injected at PIPE0 every 16 cycles (from the PULSE generator).
// You can watch the bit propagate through the chain:
//
//   cycle N  :  PIPE0 ← new_data
//   cycle N+1:  PIPE1 ← PIPE0 (old)
//   cycle N+2:  PIPE2 ← PIPE1 (old)
//   cycle N+3:  PIPE3 ← PIPE2 (old)
//
// On scope, trigger on PIPE0 rising and measure delay to PIPE1/2/3.
// The delay between stages is exactly 1 HFOSC period (83.33 ns).
// ===================================================================

// Pulse generator (defined here, also exposed in Section 5)
reg [3:0] pulse_ctr = 4'b0;
always @(posedge hf_clk)
    pulse_ctr <= pulse_ctr + 1;

// One-cycle-wide pulse when counter rolls over (every 16 cycles)
wire inject = (pulse_ctr == 4'b1111);

reg pipe0 = 1'b0;
reg pipe1 = 1'b0;
reg pipe2 = 1'b0;
reg pipe3 = 1'b0;

always @(posedge hf_clk) begin
    pipe0 <= inject;    // cycle N:   new bit enters
    pipe1 <= pipe0;     // cycle N+1: propagates
    pipe2 <= pipe1;     // cycle N+2
    pipe3 <= pipe2;     // cycle N+3
end

assign PIPE0 = pipe0;
assign PIPE1 = pipe1;
assign PIPE2 = pipe2;
assign PIPE3 = pipe3;


// ===================================================================
// SECTION 5: TIMING MARKERS
//
// PULSE    — one HFOSC-cycle wide, every 16 cycles (750 kHz rep rate)
//            Use as a trigger reference.
//
// TICK     — toggles every HFOSC cycle.  On scope this looks like
//            HFOSC ÷ 2 = 6 MHz.  Confirms the clock is running.
//
// GATE_EN  — HIGH for 8 consecutive cycles, LOW for the next 8.
//            Demonstrates clock gating / conditional enable.
//
// GATED_D  — a free-running counter that ONLY increments when
//            GATE_EN is HIGH.  Compare GATED_D transitions against
//            GATE_EN to verify gating works cycle-accurately.
//
// CYCLE_ID — bit 0 of a 4-bit counter that increments every cycle.
//            Provides a unique cycle identifier (repeats every 16).
//            Correlate with PULSE to verify exact cycle position.
// ===================================================================

// PULSE — already computed above from pulse_ctr
assign PULSE = inject;

// TICK — toggle every cycle
reg tick_r = 1'b0;
always @(posedge hf_clk)
    tick_r <= ~tick_r;
assign TICK = tick_r;

// GATE_EN — high for upper half of pulse_ctr (cycles 8..15)
wire gate_en = pulse_ctr[3];
assign GATE_EN = gate_en;

// GATED_D — counter that only advances when gate is open
reg [3:0] gated_ctr = 4'b0;
always @(posedge hf_clk) begin
    if (gate_en)
        gated_ctr <= gated_ctr + 1;
    // else: holds value — visible as flat line on scope
end
assign GATED_D = gated_ctr[0];

// CYCLE_ID — raw cycle counter (bit 0 = identifies odd/even cycles)
assign CYCLE_ID = pulse_ctr[0];


// ===================================================================
// SECTION 6: RGB LED HEARTBEAT
//
// Visual confirmation that both clock domains are alive.
// Uses a slow counter for human-visible blink rates.
//
//   RED   = HFOSC alive (toggles ~1.4 s on / 1.4 s off)
//   GREEN = LFOSC alive (toggles via CDC edge accumulator)
//   BLUE  = CDC working (blinks when CDC edges are detected)
// ===================================================================

reg [24:0] vis_ctr = 0;
always @(posedge hf_clk)
    vis_ctr <= vis_ctr + 1;

// Count CDC edges to prove LFOSC → HFOSC path works
reg [15:0] cdc_count = 0;
always @(posedge hf_clk)
    if (cdc_rising)
        cdc_count <= cdc_count + 1;

SB_RGBA_DRV #(
    .CURRENT_MODE ("0b1"),
    .RGB0_CURRENT ("0b000111"),
    .RGB1_CURRENT ("0b000111"),
    .RGB2_CURRENT ("0b000111")
) u_rgba (
    .CURREN   (1'b1),
    .RGBLEDEN (1'b1),
    .RGB0PWM  (vis_ctr[24]),     // green: HFOSC-derived ~0.7 Hz
    .RGB1PWM  (cdc_count[7]),    // blue:  CDC edge count bit — proves crossing
    .RGB2PWM  (vis_ctr[23]),     // red:   HFOSC-derived ~1.4 Hz
    .RGB0     (RGB0),
    .RGB1     (RGB1),
    .RGB2     (RGB2)
);


endmodule
