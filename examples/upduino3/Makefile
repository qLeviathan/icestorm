# UPduino 3.1 — iCE40 UP5K uwg30 build flow
# Full open-source toolchain: Yosys → nextpnr → IceStorm
#
# Targets:
#   make            — synthesize + place&route + pack bitstream
#   make prog       — program via FTDI/SPI (iceprog -S)
#   make timing     — static timing report
#   make clean      — remove build artifacts

PROJ    = top
PCF     = upduino3.pcf
DEVICE  = up5k
PACKAGE = uwg30

# Tools (override on command line if needed, e.g. make YOSYS=/opt/bin/yosys)
YOSYS   = yosys
NEXTPNR = nextpnr-ice40
ICEPACK = icepack
ICETIME = icetime
ICEPROG = iceprog

# Yosys synthesis flags
SYNTH_FLAGS = -top top -json $(PROJ).json

# nextpnr flags
PNR_FLAGS = --$(DEVICE) --package $(PACKAGE) --pcf $(PCF) --json $(PROJ).json --asc $(PROJ).asc

.PHONY: all prog timing clean

all: $(PROJ).bin

# 1. Synthesize: Verilog → JSON netlist
$(PROJ).json: $(PROJ).v
	$(YOSYS) -p 'synth_ice40 $(SYNTH_FLAGS)' $<

# 2. Place & Route: JSON + PCF → ASC
$(PROJ).asc: $(PROJ).json $(PCF)
	$(NEXTPNR) $(PNR_FLAGS)

# 3. Pack: ASC → binary bitstream
$(PROJ).bin: $(PROJ).asc
	$(ICEPACK) $< $@

# 4. Timing report
$(PROJ).rpt: $(PROJ).asc
	$(ICETIME) -d $(DEVICE) -mtr $@ $<

timing: $(PROJ).rpt
	@cat $<

# 5. Program board (SRAM mode, volatile — good for experiments)
prog: $(PROJ).bin
	$(ICEPROG) -S $<

# 6. Program board (flash mode, persistent across power cycles)
flash: $(PROJ).bin
	$(ICEPROG) $<

clean:
	rm -f $(PROJ).json $(PROJ).asc $(PROJ).bin $(PROJ).rpt
