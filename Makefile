# Incremental wrapper around `c3c build` — c3c always fully recompiles and
# relinks even when nothing changed (~19s), so gate each target on mtimes
# and skip the c3c invocation entirely when the binary is already newer
# than every source file that feeds it.
#
# Prerequisites are pulled from project.json at execute time (c-sources +
# the target's own "sources", expanding directory entries to their .c3
# files) so this file never drifts from what c3c itself actually builds.

target_sources = $(shell jq -r '.["c-sources"][]' project.json) \
                 $(shell jq -r '.targets.$(1).sources[]' project.json | while read -r s; do \
                     if [ -d "$$s" ]; then find "$$s" -name '*.c3'; else echo "$$s"; fi; \
                 done)

.PHONY: all lib test_vm batch_test_vm duktape_c3 clean

all: lib test_vm batch_test_vm duktape_c3

lib: out/lib.a
test_vm: out/test_vm
batch_test_vm: out/batch_test_vm
duktape_c3: out/duktape_c3

out/lib.a: project.json $(call target_sources,lib)
	c3c build lib

out/test_vm: project.json $(call target_sources,test_vm)
	c3c build test_vm

out/batch_test_vm: project.json $(call target_sources,batch_test_vm)
	c3c build batch_test_vm

out/duktape_c3: project.json $(call target_sources,duktape_c3)
	c3c build duktape_c3

clean:
	c3c clean
