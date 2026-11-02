TOOLS := extdisplay

.PHONY: install uninstall

install: $(addprefix install-,$(TOOLS))

uninstall: $(addprefix uninstall-,$(TOOLS))

install-%:
	./$*/install.sh

uninstall-%:
	./$*/install.sh --uninstall
