PROJECT_NAME ?= tt_um_spdif_to_i2s_kilpelaj
MAGIC_RC := $(PDK_ROOT)/sky130A/libs.tech/magic/sky130A.magicrc
TEMPLATE_FILE := tt_analog_1x2.def
TEMPLATE_FILE := tt_analog_1x2_3v3.def

.PHONY: lvs magic start

magic:
	magic -rcfile $(MAGIC_RC) $(PROJECT_NAME).mag

tt_analog_1x2.def:
	wget https://raw.githubusercontent.com/TinyTapeout/tt-support-tools/tt08/def/analog/tt_analog_1x2.def

tt_analog_1x2_3v3.def:
	wget https://raw.githubusercontent.com/TinyTapeout/tt-support-tools/tt08/def/analog/tt_analog_1x2_3v3.def

start: $(TEMPLATE_FILE)
	magic -rcfile $(MAGIC_RC) -noconsole -dnull tcl/tt-analog-draw.tcl $(TEMPLATE_FILE) $(PROJECT_NAME)

$(PROJECT_NAME).lvs.spice: $(PROJECT_NAME).mag
	magic -noconsole -dnull tcl/extract_for_lvs.tcl $(PROJECT_NAME)
	rm -f *.ext

antenna:
	magic -noconsole -dnull tcl/antenna.tcl $(PROJECT_NAME)
	rm -f *.ext

drc:
	magic -noconsole -dnull tcl/drc.tcl $(PROJECT_NAME)
	
$(PROJECT_NAME).sim.spice:
	 cd ../xschem; xschem -s -x -q \
		--command "set top_is_subckt 1; set lvs_netlist 1; set netlist_dir .; xschem netlist $(PROJECT_NAME).sim.spice" comp.sch \
		; cd ../mag

lvs.report: $(PROJECT_NAME).lvs.spice ../src/project.v
	netgen -batch lvs "../xschem/$(PROJECT_NAME).sim.spice comp" "tt_um_spdif_to_i2s_kilpelaj.lvs.spice tt_um_spdif_to_i2s_kilpelaj" $(PDK_ROOT)/sky130A/libs.tech/netgen/setup.tcl lvs.report

lvs: lvs.report
	@propOk=1; match=0; port=1; \
    if grep -q "match uniquely" lvs.report; then \
        match=1; \
    fi; \
    if grep -q "Property errors were found" lvs.report; then \
        propOk=0; \
    fi; \
    if grep -q "failed pin matching" lvs.report; then \
        match=0; \
    fi; \
    if grep -q "Final result: Netlists do not match" lvs.report; then \
        match=0; \
    fi; \
    if grep -q "port errors" lvs.report; then \
        port=0; \
    fi; \
    if grep -q "Final result: Circuits match uniquely\." lvs.report; then \
        match=1; \
    fi; \
	if [ $$match -eq 1 ] && [ $$propOk -eq 1 ] && [ $$port -eq 1 ]; then \
        echo "LVS OK"; \
	    exit 0; \
    else \
        echo "LVS FAIL: match=$$match properties=$$propOk port=$$port"; \
	    exit 1; \
    fi

update_gds:
	mkdir -p ../gds ../lef
	magic -noconsole -dnull tcl/update_gds_lef.tcl $(PROJECT_NAME)

clean:
	rm -f lvs.report *.lvs.spice *.nodes
