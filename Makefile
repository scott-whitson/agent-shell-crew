EMACS  ?= emacs
PYTHON ?= python3
# Where agent-shell and its dependencies live. The default is the stubs, so
# `make check' runs anywhere; point it at the real packages for `api-check'.
DEPS   ?= -L test/stubs
EL      = agent-shell-crew-queue.el agent-shell-crew-rpc.el agent-shell-crew.el
TESTS   = $(wildcard test/agent-shell-crew-*-test.el)
UNIT    = $(filter-out test/agent-shell-crew-api-test.el,$(TESTS))

.PHONY: check compile checkdoc test api-check clean

check: compile checkdoc test

compile:
	$(EMACS) -Q --batch -L . $(DEPS) \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(wildcard $(EL))

checkdoc:
	$(EMACS) -Q --batch -L . $(DEPS) -l test/checkdoc.el $(wildcard $(EL))

test:
	$(EMACS) -Q --batch -L . $(DEPS) -l ert \
	  $(foreach t,$(UNIT),-l $(t)) -f ert-run-tests-batch-and-exit
	$(PYTHON) -m unittest discover -s test -p 'test_*.py'

api-check:
	$(EMACS) -Q --batch -L . $(DEPS) -l ert \
	  -l test/agent-shell-crew-api-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc
