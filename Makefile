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

PREFIX ?= /usr/local

# The binary into $(PREFIX)/bin and the shell completions where bash, zsh and
# fish look. Two steps rather than install -D: BSD install has no -D.
install: bin/trndi-cli install-completions
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 bin/trndi-cli $(DESTDIR)$(PREFIX)/bin/trndi-cli

install-completions:
	install -d $(DESTDIR)$(PREFIX)/share/bash-completion/completions
	install -m 644 completions/trndi-cli.bash $(DESTDIR)$(PREFIX)/share/bash-completion/completions/trndi-cli
	install -d $(DESTDIR)$(PREFIX)/share/zsh/site-functions
	install -m 644 completions/_trndi-cli $(DESTDIR)$(PREFIX)/share/zsh/site-functions/_trndi-cli
	install -d $(DESTDIR)$(PREFIX)/share/fish/vendor_completions.d
	install -m 644 completions/trndi-cli.fish $(DESTDIR)$(PREFIX)/share/fish/vendor_completions.d/trndi-cli.fish

# Remove what install put there. The share/ directories stay: they are the
# shells' own, not ours.
uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/trndi-cli
	rm -f $(DESTDIR)$(PREFIX)/share/bash-completion/completions/trndi-cli
	rm -f $(DESTDIR)$(PREFIX)/share/zsh/site-functions/_trndi-cli
	rm -f $(DESTDIR)$(PREFIX)/share/fish/vendor_completions.d/trndi-cli.fish

.PHONY: all debug clean install install-completions uninstall
