# Makefile for the SWI-Prolog MCP pack.
#
# Run the full PLUnit test matrix:
#
#     make check
#
# test_source and test_git read the `swipl-source` root, discovered
# from the `cmake_source_directory` flag (set only for swipl built
# from a source tree).  For other installs, point it at a checkout;
# the units skip themselves cleanly if the resolved path is absent /
# not a git work-tree:
#
#     make check \
#         SWIPL_FLAGS=-Dcmake_source_directory=/path/to/swipl-devel
#
# `make -j N check` runs the suites in parallel -- each suite is a
# separate swipl process and they share no on-disk or in-process state.

SWIPL       ?= swipl
SWIPL_FLAGS ?=

#  test_utils.pl is a shared helper module, not a runnable suite --
#  drop it from the discovered list.
TEST_FILES := $(filter-out tests/test_utils.pl,$(wildcard tests/test_*.pl))
TESTS      := $(notdir $(basename $(TEST_FILES)))

.PHONY: check install $(TESTS)

check: $(TESTS)

# No-op: this is a pure-Prolog pack, so the files live in the pack
# directory and there is nothing to compile or copy.  The target is
# provided so downstream tooling (pack_install/2, distro packagers)
# can invoke `make install` uniformly.
install:
	@:

$(TESTS):
	@printf '=== %s ===\n' '$@'
	@$(SWIPL) $(SWIPL_FLAGS) -g '$@,halt' -t 'halt(1)' tests/$@.pl
