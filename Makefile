SHELL = /bin/bash

INSTALL = $(shell type -p install)
SUDO = $(shell test $$EUID -ne 0 && type -p sudo)

DESTDIR ?=
PREFIX ?= /usr/local

.PHONY: all
all:
	@echo DESTDIR=$(DESTDIR)
	@echo PREFIX=$(PREFIX)
	@echo SUDO=$(SUDO)

.PHONY: install
install:
	$(SUDO) $(INSTALL) -d -m0755 $(DESTDIR)$(PREFIX)/bin
	$(SUDO) $(INSTALL) -m0755 kernel-builder.bash $(DESTDIR)$(PREFIX)/bin/kernel-builder
	$(SUDO) $(INSTALL) -d -m0755 $(DESTDIR)$(PREFIX)/etc/default
	$(SUDO) $(INSTALL) -m0755 kernel-builder.config $(DESTDIR)$(PREFIX)/etc/default/kernel-builder
