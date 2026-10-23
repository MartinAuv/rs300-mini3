obj-m += rs300.o
rs300-y := src/rs300.o

ifneq ($(wildcard /usr/src/nvidia/nvidia-public/include),)
NVIDIA_OOT_DIR ?= /usr/src/nvidia/nvidia-public
else
NVIDIA_OOT_DIR ?= /usr/src/nvidia/nvidia-oot
endif

ccflags-y += -I$(NVIDIA_OOT_DIR)/include -I$(src)/src/include

ifdef DEBUG
ccflags-y += -DDEBUG
endif

KERNELRELEASE ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KERNELRELEASE)/build
SRCDIR ?= $(CURDIR)/src
EXTRA_SYMVERS := $(CURDIR)/.nvidia-extra.symvers
KBUILD_EXTRA_SYMBOLS += $(EXTRA_SYMVERS)

ifneq (,$(findstring n,$(MAKEFLAGS)))
all:
	@echo "DRY-RUN: $(MAKE) -C $(KDIR) M=$(CURDIR) modules"
else
all: $(EXTRA_SYMVERS)
	$(MAKE) -C $(KDIR) M=$(CURDIR) KBUILD_EXTRA_SYMBOLS="$(EXTRA_SYMVERS)" modules
endif

$(EXTRA_SYMVERS): $(NVIDIA_OOT_DIR)/Module.symvers
	@if [ -f "$(KDIR)/Module.symvers" ]; then \
		awk 'NR==FNR { seen[$$2]=1; next } !seen[$$2]' "$(KDIR)/Module.symvers" "$(NVIDIA_OOT_DIR)/Module.symvers" > "$@"; \
	else \
		cp "$(NVIDIA_OOT_DIR)/Module.symvers" "$@"; \
	fi

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
	rm -f $(EXTRA_SYMVERS) rs300-cam1.dtbo

install:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules_install
	depmod -a

dtbo: rs300-cam1.dtbo

rs300-cam1.dtbo: $(SRCDIR)/rs300-cam1-overlay.dts
	dtc -@ -H epapr -Wno-unit_address_vs_reg -Wno-graph_child_address -Wno-gpios_property -I dts -O dtb -o $@ $<
