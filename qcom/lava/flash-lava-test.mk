################################################################################
# qcom/lava/flash-lava-test.mk: flash-lava-test for any Qualcomm board
#
# 'make flash-lava-test' flashes a board in the LAVA lab
# (https://lava.infra.foundries.io) with this build, boots it and runs the
# test definitions of the board's plan file, then prints the results per
# test suite. A board makefile sets the variables below and includes this
# file after the flash-lava-package target it builds on (see
# qcom/lava/README.md).
#
# Targets:
#   flash-lava-test          package, write the job, upload, submit, follow
#                            (always built with TEST=y)
#   flash-lava-test-package  the tarballs the job downloads
#   flash-lava-test-job      only write the job ($(LAVA_TEST_JOB))
#
# Variables (board makefile; the ?= ones can be overridden on the command
# line):
#   LAVA_TEST_REPO, LAVA_TEST_BRANCH
#                         the test-definitions repository and branch the
#                         job takes the test definitions from
#   LAVA_TEST_PLAN        plan file: one test definition per line (see
#                         qcom/lava/flash-lava-test.py)
#   LAVA_DEVICE_TYPE      LAVA device type of the board
#   LAVA_QDL_STORAGE, LAVA_QDL_RAWPROGRAM, LAVA_QDL_PATCH
#                         the qdl boot method: storage type, rawprogram and
#                         patch files
#   LAVA_QDL_RAMDUMP      y: qdl debug and RAM dump collection
#   LAVA_PROMPTS          shell prompts after login, as shell words
#   LAVA_TEST_FLASH_TARGET, LAVA_TEST_FLASH_TARBALL
#                         the target that makes the flash tarball, and the
#                         tarball
#   LAVA_TEST_UKI_IMAGE, LAVA_TEST_UKI_DTB, LAVA_TEST_UKI_STUB,
#   LAVA_TEST_UKI_INITRAMFS, LAVA_TEST_UKI_BOOTAA64
#                         the UKI ingredients the job rebuilds the UKI from
#   LAVA_TEST_UKI_CMDLINE the kernel command line of that UKI
#   LAVA_TEST_JOB_ARGS    more flash-lava-test.py options (timeouts, ...)
################################################################################
LAVA_TEST_REPO      ?= https://github.com/EmbeddedAndroid/test-definitions.git
LAVA_TEST_BRANCH    ?= openbootstack-tests
LAVA_TEST_PLAN      ?= $(CURDIR)/$(PLATFORM)/lava/test-plan
LAVA_TEST_OUT       ?= $(CURDIR)/$(PLATFORM)/output
LAVA_TEST_JOB       ?= $(LAVA_TEST_OUT)/$(PLATFORM)-flash-lava-test.yaml
LAVA_TEST_JOB_NAME  ?= $(PLATFORM)-flash-lava-test
LAVA_QDL_PATCH      ?= patch0.xml
LAVA_PROMPTS        ?= '\n\# '

LAVA_TEST_INGREDIENTS_DIR     = $(LAVA_TEST_OUT)/flash-lava-test-ingredients
LAVA_TEST_INGREDIENTS_TARBALL = $(LAVA_TEST_OUT)/$(PLATFORM)-ukify-ingredients.tar.gz

lava-test-args = \
	--device-type $(LAVA_DEVICE_TYPE) \
	--job-name $(LAVA_TEST_JOB_NAME) \
	--plan $(LAVA_TEST_PLAN) \
	--test-repo $(LAVA_TEST_REPO) \
	--test-branch $(LAVA_TEST_BRANCH) \
	--storage $(LAVA_QDL_STORAGE) \
	--rawprogram '$(strip $(LAVA_QDL_RAWPROGRAM))' \
	--patch '$(strip $(LAVA_QDL_PATCH))' \
	$(if $(filter y,$(LAVA_QDL_RAMDUMP)),--ramdump) \
	--prompts "$(LAVA_PROMPTS)" \
	--flash-name $(notdir $(LAVA_TEST_FLASH_TARBALL)) \
	--uki-cmdline '$(strip $(LAVA_TEST_UKI_CMDLINE))' \
	--uki-dtb $(notdir $(LAVA_TEST_UKI_DTB))
lava-test-uploads = FLASH=$(LAVA_TEST_FLASH_TARBALL) \
		    INGREDIENTS=$(LAVA_TEST_INGREDIENTS_TARBALL)

.PHONY: flash-lava-test flash-lava-test-package flash-lava-test-job

# The plan's tests need their packages in the rootfs: build with TEST=y
# (qcom/test.mk reads TEST when the makefile is parsed, so re-run make).
ifneq ($(TEST),y)
flash-lava-test flash-lava-test-package:
	$(MAKE) -f $(firstword $(MAKEFILE_LIST)) TEST=y $@
else
flash-lava-test: flash-lava-test-package flash-lava-test-job
	$(CURDIR)/qcom/lava/submit-test.sh $(LAVA_TEST_JOB) $(lava-test-uploads)
endif

flash-lava-test-job:
	@mkdir -p $(dir $(LAVA_TEST_JOB))
	python3 $(CURDIR)/qcom/lava/flash-lava-test.py $(lava-test-args) \
		$(LAVA_TEST_JOB_ARGS) -o $(LAVA_TEST_JOB)
	@echo "LAVA job: $(LAVA_TEST_JOB)"

# The job rebuilds the UKI on the LAVA worker from the ingredients packed
# here, and writes it into a copy of the flash tarball.
ifeq ($(TEST),y)
flash-lava-test-package: $(LAVA_TEST_FLASH_TARGET)
	rm -rf $(LAVA_TEST_INGREDIENTS_DIR)
	@mkdir -p $(LAVA_TEST_INGREDIENTS_DIR)
	@for pair in "$(LAVA_TEST_UKI_IMAGE):vmlinuz.efi" \
		     "$(LAVA_TEST_UKI_DTB):$(notdir $(LAVA_TEST_UKI_DTB))" \
		     "$(LAVA_TEST_UKI_INITRAMFS):rootfs.cpio.gz" \
		     "$(LAVA_TEST_UKI_STUB):linuxaa64.efi.stub" \
		     "$(LAVA_TEST_UKI_BOOTAA64):bootaa64.efi"; do \
		src="$${pair%%:*}"; dst="$${pair##*:}"; \
		[ -f "$$src" ] || { echo "ERROR: $$src not found"; exit 1; }; \
		cp -f "$$src" "$(LAVA_TEST_INGREDIENTS_DIR)/$$dst"; \
	done
	tar -czf $(LAVA_TEST_INGREDIENTS_TARBALL) -C $(LAVA_TEST_INGREDIENTS_DIR) .
	@echo "LAVA test tarballs: $(LAVA_TEST_FLASH_TARBALL)"
	@echo "                    $(LAVA_TEST_INGREDIENTS_TARBALL)"
endif
