# Build BEAM.com with GNU make 4: the make of cosmocc
# (build/cosmocc/bin/make, after "make toolchain"), or another GNU make.
#
#   make                 all the steps of the build (not test and unit)
#   make STEP...         the steps, and each step that they need first
#   make redo-STEP       the step again, also when its inputs did not change
#   make JIT=0 OUT=build/beam-emu.com    a build with other settings
#
# The steps are in scripts/steps.sh, and the settings are the variables
# that it lists (from the environment or from the command line). Each
# step writes a stamp, build/stamps/STEP. A step runs again when a step
# that it needs ran again, when one of its files in this repository
# changed, or when a setting changed (build/stamps/config).
#
# The steps run one at a time (.NOTPARALLEL): they share the OTP tree.
# For example, multicall links the emulator again, while elixir and
# wasm_runtime run the erl of that tree. Each step uses JOBS processes.
#
# A change of scripts/steps.sh does not run the steps again. Use
# "make redo-STEP" for the step that changed.

BUILD ?= $(CURDIR)/build
export BUILD
STAMPS := $(BUILD)/stamps
# A step starts with no MAKEFLAGS: the make of OTP in a step must not get
# the variables of this command line (JIT=0 is a setting of the steps,
# from the environment, not a variable of the Makefiles of OTP).
STEP = unset MAKEFLAGS MFLAGS MAKELEVEL MAKEOVERRIDES; sh $(CURDIR)/scripts/steps.sh

# The settings of scripts/steps.sh. A change of one of them runs the build
# again from the step configure (or from the first step that reads it).
SETTINGS := OTP_VERSION OTP_COMMIT COSMOCC_VERSION COSMOCC_SHA256 OPENSSL_VERSION \
  OPENSSL_COMMIT EMSDK_VERSION EMSDK_COMMIT SQLITE ESQLITE_COMMIT SQLITE_VERSION \
  SQLITE_YEAR SQLITE_SHA256 EXQLITE_VERSION EXQLITE_SHA256 BCRYPT_ELIXIR_VERSION \
  BCRYPT_ELIXIR_SHA256 ARGON2_ELIXIR_VERSION ARGON2_ELIXIR_SHA256 \
  PICOSAT_ELIXIR_VERSION PICOSAT_ELIXIR_SHA256 EXTRA_NIFS WASM WAMR_VERSION \
  WAMR_COMMIT WASM_RUNTIME EMSDK ELIXIR ELIXIR_VERSION ELIXIR_COMMIT \
  REBAR3_VERSION REBAR3_SHA256 OTP_APPS HEX REBAR3 COSMOCC CC AR CXX JIT OUT

STEPS := toolchain openssl otp configure sqlite nifs wasm make elixir release \
  multicall wasm_runtime bundle

.PHONY: all $(STEPS) test unit hex_nifs FORCE
.NOTPARALLEL:

all: bundle

# The files of this repository that each step reads (git knows them; a
# build output in the work tree is not one of them).
files = $(shell git -C $(CURDIR) ls-files $(1))
OTP_FILES := $(call files,patches/otp c_src/cosmo/*.c c_src/cosmo/*.h)
WASM_FILES := $(call files,c_src/wasm)
RUNTIME_FILES := $(call files,wasm/erts c_src/erts_wasm)
BUNDLE_FILES := $(call files,src priv licenses c_src/cosmo/*.inetrc LICENSE NOTICE)

$(STAMPS):
	mkdir -p $@

# The settings, written again only when they change.
$(STAMPS)/config: FORCE | $(STAMPS)
# Only the values of the environment and of the command line: make has
# its own values of CC, AR and CXX, which the steps do not get.
	@printf '%s\n' $(foreach v,$(SETTINGS),'$(v)=$(if $(filter environment% command line,$(origin $(v))),$($(v)))') > $@.new
	@if cmp -s $@.new $@; then rm -f $@.new; else mv $@.new $@; fi

# step NAME, NEEDS...: the stamp of the step NAME, after the stamps and the
# files that it needs.
define step
$(1): $(STAMPS)/$(1)
$(STAMPS)/$(1): $(2) | $(STAMPS)
	$$(STEP) $(1)
	@touch $$@
endef

$(eval $(call step,toolchain,$(STAMPS)/config))
$(eval $(call step,openssl,$(STAMPS)/toolchain))
$(eval $(call step,otp,$(STAMPS)/config $(OTP_FILES)))
$(eval $(call step,configure,$(STAMPS)/otp $(STAMPS)/openssl c_src/cosmo/erts_cosmo.h c_src/cosmo/noshared))
$(eval $(call step,sqlite,$(STAMPS)/configure))
$(eval $(call step,nifs,$(STAMPS)/configure $(STAMPS)/sqlite))
$(eval $(call step,wasm,$(STAMPS)/configure $(WASM_FILES)))
$(eval $(call step,make,$(STAMPS)/configure $(STAMPS)/sqlite $(STAMPS)/nifs $(STAMPS)/wasm c_src/cosmo/depcc))
$(eval $(call step,elixir,$(STAMPS)/make))
$(eval $(call step,release,$(STAMPS)/elixir))
$(eval $(call step,multicall,$(STAMPS)/release))
$(eval $(call step,wasm_runtime,$(STAMPS)/multicall $(RUNTIME_FILES)))
$(eval $(call step,bundle,$(STAMPS)/wasm_runtime $(BUNDLE_FILES)))

# The checks run each time.
test: $(STAMPS)/bundle
	$(STEP) test

unit: $(STAMPS)/elixir
	$(STEP) unit

# For wasm/erts/build.sh: the NIFs of Elixir packages for its runtime.
hex_nifs:
	$(STEP) hex_nifs

redo-%:
	rm -f $(STAMPS)/$*
	$(MAKE) $*
