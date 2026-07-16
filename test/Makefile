# Makefile
# Runs the self-checking SystemVerilog testbench (spdif_to_i2s_tb) directly
# under Icarus Verilog. The testbench drives the wrapped design through its
# chip pins and reports PASS / $fatal on its own, so no cocotb is used.

TOPLEVEL = spdif_to_i2s_tb
TB       = $(PWD)/spdif_to_i2s_tb.sv
SRC_DIR  = $(PWD)/../src
PROJECT_SOURCES = project.v spdif_rx.sv i2s_tx.sv mute_detect.sv pwm_audio.sv spdif_to_i2s.sv

ifneq ($(GATES),yes)

# RTL simulation
SOURCES = $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
DEFINES =

else

# Gate-level simulation: sky130 cell models + the synthesised netlist
SOURCES = $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v \
          $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v \
          $(PWD)/gate_level_netlist.v
DEFINES = -DGL_TEST -DFUNCTIONAL -DUSE_POWER_PINS -DSIM -DUNIT_DELAY=\#1

endif

all: sim.vvp
	vvp -N sim.vvp | tee run.log || true
	@# Emit a JUnit results.xml for the Tiny Tapeout flow (RTL + gate-level test
	@# steps check `test -f results.xml` and `! grep failure results.xml`).
	@# On pass the file must contain no "failure" substring.
	@if grep -q "PASS: 32 consecutive L/R samples" run.log; then \
		printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites><testsuite name="spdif2i2s"><testcase classname="spdif_to_i2s_tb" name="self_check"/></testsuite></testsuites>\n' > results.xml; \
	else \
		printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites><testsuite name="spdif2i2s"><testcase classname="spdif_to_i2s_tb" name="self_check"><failure message="self-check did not reach PASS"/></testcase></testsuite></testsuites>\n' > results.xml; \
	fi

sim.vvp: $(SOURCES) $(TB)
	iverilog -g2012 -o sim.vvp -s $(TOPLEVEL) -I$(SRC_DIR) $(DEFINES) $(SOURCES) $(TB)

clean:
	rm -f sim.vvp *.fst results.xml run.log

.PHONY: all clean
