# Build BEAM.com with GNU make 4.3 or later: the make of cosmocc
# (build/cosmocc/bin/make, after "make toolchain"), or another GNU make.
#
#   make                 all the steps of the build (not test and unit)
#   make STEP...         the steps, and each step that they need first
#   make redo-STEP       the step again, also when its inputs did not change
#   make JIT=0 OUT=build/beam-emu.com    a build with other settings
#
# The steps are in scripts/steps.sh, and the settings are the variables
# that it lists (from the environment or from the command line). Each
# step has a key: the SHA-256 of its code in scripts/steps.sh, of the
# settings that this code reads, and of its files in this repository
# (docs/BUILDING.md, "The keys of the steps"). A step runs again when its
# key changed, or when a step that it needs ran again. A new time of a
# file, as in a new checkout, does not run a step again.
#
# First, make writes the key of each step in build/stamps/STEP.key, and
# its inputs in build/stamps/STEP.inputs. A step that ran writes its key
# in its stamp, build/stamps/STEP.
#
# The steps run one at a time (.NOTPARALLEL): they share the OTP tree.
# For example, multicall links the emulator again, while elixir and
# wasm_runtime run the erl of that tree. Each step uses JOBS processes.

BUILD ?= $(CURDIR)/build
export BUILD
STAMPS := $(BUILD)/stamps
# A step starts with no MAKEFLAGS: the make of OTP in a step must not get
# the variables of this command line (JIT=0 is a setting of the steps,
# from the environment, not a variable of the Makefiles of OTP).
STEP = unset MAKEFLAGS MFLAGS MAKELEVEL MAKEOVERRIDES; sh $(CURDIR)/scripts/steps.sh

# The steps with a key: KEY_STEPS of scripts/steps.sh has the same list.
STEPS := toolchain openssl otp configure sqlite nifs wasm make elixir release \
  multicall wasm_runtime bundle
KEYS := $(STEPS:%=$(STAMPS)/%.key)

.PHONY: all $(STEPS) test unit hex_nifs FORCE
.NOTPARALLEL:

all: bundle

$(STAMPS):
	mkdir -p $@

# The keys, in one run of scripts/steps.sh. It writes a key again only
# when the key changed, so only a changed key gets a new time.
$(KEYS) &: FORCE | $(STAMPS)
	@$(STEP) keys $(STEPS)

# step NAME, NEEDS...: the stamp of the step NAME, after its key and the
# stamps of the steps that it needs.
define step
$(1): $(STAMPS)/$(1)
$(STAMPS)/$(1): $(STAMPS)/$(1).key $(2) | $(STAMPS)
	$$(STEP) $(1)
	@cp $(STAMPS)/$(1).key $$@
endef

$(eval $(call step,toolchain))
$(eval $(call step,openssl,$(STAMPS)/toolchain))
$(eval $(call step,otp))
$(eval $(call step,configure,$(STAMPS)/otp $(STAMPS)/openssl))
$(eval $(call step,sqlite,$(STAMPS)/configure))
$(eval $(call step,nifs,$(STAMPS)/configure $(STAMPS)/sqlite))
$(eval $(call step,wasm,$(STAMPS)/configure))
$(eval $(call step,make,$(STAMPS)/configure $(STAMPS)/sqlite $(STAMPS)/nifs $(STAMPS)/wasm))
$(eval $(call step,elixir,$(STAMPS)/make))
$(eval $(call step,release,$(STAMPS)/elixir))
$(eval $(call step,multicall,$(STAMPS)/release))
$(eval $(call step,wasm_runtime,$(STAMPS)/multicall))
$(eval $(call step,bundle,$(STAMPS)/wasm_runtime))

# The checks run each time.
test: $(STAMPS)/bundle
	$(STEP) test

unit: $(STAMPS)/bundle
	$(STEP) unit

# For wasm/erts/build.sh: the NIFs of Elixir packages for its runtime.
hex_nifs:
	$(STEP) hex_nifs

redo-%:
	rm -f $(STAMPS)/$*
	$(MAKE) $*
