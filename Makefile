# JTAG TAP controller -- simulation makefile (Icarus Verilog + GTKWave)
IVERILOG = iverilog -g2012
VVP      = vvp
GTKWAVE  = gtkwave

RTL = rtl/jtag_pkg.sv rtl/jtag_tap_fsm.sv
TB  = tb/tb_jtag_tap_fsm.sv
OUT = sim/tap_fsm.out
VCD = sim/tap_fsm.vcd

.PHONY: all sim wave clean

all: sim

$(OUT): $(RTL) $(TB)
	$(IVERILOG) -o $(OUT) $(RTL) $(TB)

sim: $(OUT)        ## compile + run the self-checking testbench
	$(VVP) $(OUT)

wave: sim          ## run, then open the waveform in GTKWave
	$(GTKWAVE) $(VCD) &

clean:
	rm -f $(OUT) $(VCD)
