#------------------------------------------------------------------------------
# Generic HDA Codec — Makefile
#------------------------------------------------------------------------------
# Usage:
#   make                 — build & run ALC269 (default)
#   make CHIP=ALC269     — build & run ALC269
#   make CHIP=ALC662     — build & run ALC662
#   make CHIP=ALC892     — build & run ALC892
#   make CHIP=ALC256     — build & run ALC256
#   make all             — run all four chips
#   make clean
#------------------------------------------------------------------------------

IVERILOG = iverilog
VVP      = vvp
IFLAGS   = -g2012 -Wall -I../rtl/generic

RTL_DIR  = ../rtl/generic
TB_DIR   = ../tb

RTL_SRC  = $(RTL_DIR)/hda_codec_pkg.sv  \
           $(RTL_DIR)/hda_link.sv        \
           $(RTL_DIR)/hda_widget_regs.sv \
           $(RTL_DIR)/hda_verb_engine.sv \
           $(RTL_DIR)/hda_audio_path.sv  \
           $(RTL_DIR)/hda_gpio_ctrl.sv   \
           $(RTL_DIR)/hda_beep_gen.sv    \
           $(RTL_DIR)/hda_spdif_out.sv   \
           $(RTL_DIR)/hda_pwr_mgmt.sv    \
           $(RTL_DIR)/hda_codec_top.sv

TB_SRC   = $(TB_DIR)/hda_codec_bfm.sv   \
           $(TB_DIR)/hda_codec_tb.sv

# Map chip name to numeric ID
ifeq ($(CHIP),ALC662)
  CHIP_ID = 1
else ifeq ($(CHIP),ALC892)
  CHIP_ID = 2
else ifeq ($(CHIP),ALC256)
  CHIP_ID = 3
else
  CHIP    ?= ALC269
  CHIP_ID  = 0
endif

SIM_OUT  = hda_codec_$(CHIP).vvp

.PHONY: run all clean

run: $(SIM_OUT)
	$(VVP) $(SIM_OUT)

$(SIM_OUT): $(RTL_SRC) $(TB_SRC)
	$(IVERILOG) $(IFLAGS) -DCHIP_ID=$(CHIP_ID) -o $@ $(RTL_SRC) $(TB_SRC)

all:
	$(MAKE) CHIP=ALC269 run
	$(MAKE) CHIP=ALC662 run
	$(MAKE) CHIP=ALC892 run
	$(MAKE) CHIP=ALC256 run

clean:
	rm -f hda_codec_*.vvp dump.vcd
