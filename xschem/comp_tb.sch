v {xschem version=3.4.8RC file_version=1.3}
G {}
K {}
V {}
S {}
F {}
E {}
B 2 320 -195 430 -95 {name=l1
flags=graph,unlocked
lock=1
color=8
node="tcleval([xschem translate l1 @#0:net_name])"
}
T {} 10 270 0 0 0.4 0.4 {.lib /foss/pdks/sky130A/libs.tech/ngspice/sky130.lib.spice tt
.tran 10n 80u
.control
  run
  plot v(dig_in) v(analog_in) v(comp_out)
.endc}
N -120 -50 -30 -50 {lab=#net1}
N -120 170 -60 170 {lab=0}
N -60 70 -60 170 {lab=0}
N -190 110 -120 110 {lab=analog_in}
N -190 -70 -190 110 {lab=analog_in}
N -190 -70 -30 -70 {lab=analog_in}
N -160 -30 -30 -30 {lab=dig_in}
N -220 -30 -220 170 {lab=dig_in}
N -220 170 -190 170 {lab=dig_in}
N 270 -70 300 -70 {lab=comp_out}
N -120 70 -60 70 {lab=0}
N -160 -30 -160 10 {lab=dig_in}
N -60 -10 -30 -10 {lab=0}
N -60 -10 -60 70 {lab=0}
N -120 10 -120 70 {lab=0}
N -220 -30 -160 -30 {lab=dig_in}
N -160 70 -120 70 {lab=0}
C {vsource.sym} -120 -20 0 0 {name=Vdd value=1.8 savecurrent=false}
C {capa.sym} -120 140 0 0 {name=C1
m=1
value=1n
footprint=1206
device="ceramic capacitor"}
C {res.sym} -190 140 0 0 {name=R1
value=10k
footprint=1206
device=resistor
m=1}
C {scope.sym} 300 -70 0 0 {name=l1
attach=l1}
C {vsource.sym} -160 40 0 0 {name=V1 value="dc 0 PULSE(0 1.8 5u 1n 1n 50u 100u)" savecurrent=false}
C {comp.sym} 120 -40 0 0 {name=x1
type: subcircuit
format: @name @pins @symname}
C {code_shown.sym} 30 130 0 0 {name=s1 only_toplevel=false value=".lib /foss/pdks/sky130A/libs.tech/ngspice/sky130.lib.spice tt
.tran 10n 80u
.control
  run
  plot v(dig_in) v(analog_in) v(comp_out)
.endc"}
C {lab_wire.sym} -90 -70 0 0 {name=p2 lab=analog_in
}
C {lab_wire.sym} 290 -70 0 0 {name=p1 lab=comp_out}
C {lab_wire.sym} -220 -30 0 0 {name=p3 sig_type=std_logic lab=dig_in}
C {gnd.sym} -60 170 0 0 {name=l2 lab=0}
