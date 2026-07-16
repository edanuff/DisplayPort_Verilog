CC ?= cc
CFLAGS ?= -std=c11 -Wall -Wextra -Wpedantic -Werror -O2
CPPFLAGS ?= -Iinclude -Iexamples

SOURCES := src/fusb302.c src/usbc_port.c examples/esp32s3_integration.c
OBJECTS := $(SOURCES:.c=.o)
TEST := tests/test_pd

.PHONY: all check clean

all: $(OBJECTS)

$(TEST): tests/test_pd.c include/usb_pd.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $< -o $@

check: all $(TEST)
	./$(TEST)
	@if command -v iverilog >/dev/null 2>&1; then \
		iverilog -g2012 -s tb_usbc_hpd -o /tmp/usbc_hpd.vvp \
			rtl/usbc_dp_control.sv ../src/auxch/hotplug_decode.v \
			tests/tb_usbc_hpd.sv; \
		vvp /tmp/usbc_hpd.vvp; \
	fi

clean:
	rm -f $(OBJECTS) $(TEST)
