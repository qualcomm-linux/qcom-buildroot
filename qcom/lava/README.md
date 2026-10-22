# qcom/lava: flash-lava-test for every Qualcomm board

`make flash-lava-test` flashes a board in the LAVA lab
(<https://lava.infra.foundries.io>) with your build, boots it, runs the
board's test plan from a
[test-definitions](https://github.com/EmbeddedAndroid/test-definitions)
repository and prints the results per test suite. Nobody needs the board on
their desk; a LAVA account with an API token is enough.

```sh
make all                        # or whatever the board builds
make flash-lava-test            # package, upload, submit, follow (builds with TEST=y)
make flash-lava-test-job        # only write the job (<board>/output/<board>-flash-lava-test.yaml)
make flash-lava-test LAVA_TEST_BRANCH=my-branch LAVA_TEST_REPO=https://github.com/me/test-definitions.git
```

The LAVA API token is `$LAVA_TOKEN`, or the `X-Lava-Token` header of the
`lava` MCP server in `~/.claude.json` (`$CLAUDE_JSON`).

`flash-lava-test` and `flash-lava-test-package` re-run make with `TEST=y`, so
the rootfs has the packages of the plan's tests (`qcom/test.mk`, default
`TEST=n`).

## Files

| File | What it does |
|---|---|
| `flash-lava-test.mk` | The targets; a board makefile sets its variables and includes it |
| `flash-lava-test.py` | Writes the LAVA job from the board variables and the plan file |
| `submit-test.sh` | Uploads the tarballs, fills in their URLs, submits the job, follows it and prints the results |
| `mint_lava.py` | Mints an upload slot through the LAVA MCP (`create_artifact_upload`) |
| `test_flash_lava_test.py` | Unit tests: `python3 -m unittest discover -s qcom/lava` |

## The plan file

`<board>/lava/test-plan` lists the test definitions the job runs, in order,
one per line:

```
# <name> <path in the test-definitions repository> [PARAM=value ...]
boot-handoff  automated/linux/boot-handoff/boot-handoff.yaml CPUS=8 TEE=optee
fastrpc       automated/linux/fastrpc/fastrpc.yaml TESTS="adsp:adsp:0:0 cdsp:cdsp:3:0"
```

Values are shell words. The test definitions come from `LAVA_TEST_REPO` at
`LAVA_TEST_BRANCH`.

## How the test overlay reaches the board

LAVA puts the test definitions and its helpers into an overlay that it
normally unpacks into the deployed root filesystem. Here the root filesystem
is the Buildroot initramfs inside the UKI, which LAVA cannot change. The job
first downloads the flash tarball and the UKI ingredients (kernel, DTB,
initramfs, UKI stub, `bootaa64.efi`; `flash-lava-test-package` packs them),
and a `postprocess` container rebuilds the UKI with the overlay appended to
the initramfs, writes `efi.bin` into a copy of the tarball and flashes that.
The image stays as it is.

## Board variables

| Variable | Meaning |
|---|---|
| `LAVA_DEVICE_TYPE` | LAVA device type |
| `LAVA_QDL_STORAGE`, `LAVA_QDL_RAWPROGRAM`, `LAVA_QDL_PATCH` | The qdl boot: storage, rawprogram and patch files |
| `LAVA_QDL_RAMDUMP` | `y`: qdl debug output and RAM dump collection |
| `LAVA_PROMPTS` | Shell prompts after login, as shell words |
| `LAVA_TEST_FLASH_TARGET`, `LAVA_TEST_FLASH_TARBALL` | The make target that builds the flash tarball, and the tarball |
| `LAVA_TEST_UKI_*` | The UKI ingredients and the kernel command line |
| `LAVA_TEST_JOB_ARGS` | More `flash-lava-test.py` options (timeouts) |

The job is public: `submit-test.sh` puts the name of the LAVA remote
artifact token in it, never the upload secret, and LAVA substitutes the
secret when it downloads the tarball.
