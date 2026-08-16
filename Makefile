# trndi-cli — LCL-free console front end for Trndi.
# Builds against the vendored trndi submodule (X_CONSOLE native + API layer).

T := vendor/trndi
FPC ?= fpc

# Extra flags from the environment, e.g. FPCEXTRA='-Fl/usr/local/lib' on BSD.
FPCEXTRA ?=

UNITDIRS := -Fu$(T)/units/trndi -Fu$(T)/units/trndi/api \
            -Fu$(T)/units/slicke -Fu$(T)/units/misc
FPCFLAGS := -Mobjfpc -Sh -dX_CONSOLE -dWITHTHREADS $(UNITDIRS) -Fi$(T)/inc \
            -FUbuild -FEbin -otrndi-cli $(FPCEXTRA)

all: bin/trndi-cli

bin/trndi-cli: src/trndicli.pas src/trndicli.settings.pas $(wildcard $(T)/units/trndi/*.pp $(T)/units/trndi/api/*.pp)
	@mkdir -p build bin
	$(FPC) $(FPCFLAGS) src/trndicli.pas

debug: src/trndicli.pas
	@mkdir -p build bin
	$(FPC) $(FPCFLAGS) -g -gl -gh src/trndicli.pas

clean:
	rm -rf build bin

.PHONY: all debug clean
