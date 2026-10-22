#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""flash-lava-test.py: write the LAVA job of 'make flash-lava-test'.

The job flashes a lab board with this build, boots it and runs the test
definitions of the board's plan file from a test-definitions repository.
Everything board specific comes from the options, which the board makefile
sets through qcom/lava/flash-lava-test.mk.

The rootfs is the initramfs in the UKI, which LAVA's test overlay (the test
definitions and LAVA's helpers) cannot reach. A 'downloads' deploy fetches
the flash tarball and the UKI ingredients (kernel, DTB, initramfs, stub,
bootaa64.efi), and its postprocess step rebuilds the UKI with the overlay
appended to the initramfs, writes efi.bin into a copy of the tarball, and
the qdl deploy flashes that copy.

Plan file: one test definition per line, '#' starts a comment:

  <name> <path in the test-definitions repository> [PARAM=value ...]

Values are shell words (quote values with spaces).

Artifact URLs and tokens are placeholders (<FLASH_URL>, <FLASH_TOKEN>,
<INGREDIENTS_URL>, <INGREDIENTS_TOKEN>) that qcom/lava/submit-test.sh
replaces with the upload URL and the name of the LAVA remote artifact
token holding its secret, so the job can be public.
"""
import argparse
import json
import re
import shlex
import sys

def parse_plan(path):
    """Return the plan's test definitions as (name, path, {param: value})."""
    tests = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            try:
                words = shlex.split(line, comments=True)
            except ValueError as e:
                raise SystemExit("%s:%d: %s" % (path, n, e))
            if not words:
                continue
            if len(words) < 2:
                raise SystemExit("%s:%d: expected <name> <path> [PARAM=value ...]" % (path, n))
            params = {}
            for w in words[2:]:
                if "=" not in w:
                    raise SystemExit("%s:%d: %s is not PARAM=value" % (path, n, w))
                k, v = w.split("=", 1)
                params[k] = v
            tests.append((words[0], words[1], params))
    if not tests:
        raise SystemExit("%s: no test definitions" % path)
    return tests


def definitions(a, tests):
    out = []
    for name, path, params in tests:
        d = {"name": name, "from": "git", "repository": a.test_repo,
             "branch": a.test_branch, "path": path}
        if params:
            d["parameters"] = params
        out.append(d)
    return out


def login_boot(a):
    boot = {"namespace": "target", "method": "minimal"}
    boot["auto_login"] = {"login_prompt": a.login_prompt, "username": "root"}
    boot["prompts"] = a.prompt
    boot["timeout"] = {"minutes": a.login_minutes}
    return {"boot": boot}


def deploy_initramfs(a):
    flash = a.flash_name
    rebuilt = flash.replace(".qcomflash.tar.gz", "-ukified.qcomflash.tar.gz")
    steps = [
        "apt-get update -qq",
        "apt-get install -y -qq systemd-ukify mtools dosfstools binutils tar gzip cpio findutils >/dev/null 2>&1",
        "mkdir -p flashout overlaymerge",
        "tar -xzf %s -C flashout" % flash,
        "ls overlay*.tar.gz >/dev/null 2>&1 && tar -xzf overlay*.tar.gz -C overlaymerge || true",
        "cp ingredients/rootfs.cpio.gz combined-rootfs.cpio.gz",
        "ls -A overlaymerge | grep -q . && (cd overlaymerge && find * | cpio -o -H newc -R +0:+0 | gzip -9 >> ../combined-rootfs.cpio.gz) || true",
        "ukify build --linux=ingredients/vmlinuz.efi --initrd=combined-rootfs.cpio.gz "
        "--cmdline=%s --efi-arch=aa64 --stub=ingredients/linuxaa64.efi.stub "
        "--os-release=@/etc/os-release --devicetree=ingredients/%s --output=uki.efi"
        % (shlex.quote(a.uki_cmdline), a.uki_dtb),
        "truncate -s %s efi.bin" % a.efi_size,
        "mkfs.fat -F 32 -S 4096 efi.bin",
        "mmd -i efi.bin ::/EFI",
        "mmd -i efi.bin ::/EFI/BOOT",
        "mmd -i efi.bin ::/EFI/Linux",
        "mcopy -i efi.bin ingredients/bootaa64.efi ::/EFI/BOOT/bootaa64.efi",
        "mcopy -i efi.bin uki.efi ::/EFI/Linux/uki.efi",
        "cp efi.bin flashout/efi.bin",
        "(cd flashout && tar -czf ../%s .)" % rebuilt,
        "ls -la %s" % rebuilt,
    ]
    return [
        {"deploy": {
            "namespace": "target",
            "to": "downloads",
            "timeout": {"minutes": a.download_minutes},
            "images": {
                "ingredients": {"url": "<INGREDIENTS_URL>",
                                "headers": {"Authorization": "<INGREDIENTS_TOKEN>"},
                                "archive": "tar"},
                "flash": {"url": "<FLASH_URL>",
                          "headers": {"Authorization": "<FLASH_TOKEN>"}},
            },
            "postprocess": {"docker": {"image": "ubuntu:24.04", "steps": steps}},
        }},
        {"deploy": {
            "namespace": "target",
            "to": "qdl",
            "qcomflash": {"url": "downloads://%s" % rebuilt},
            "timeout": {"minutes": a.deploy_minutes},
        }},
    ]


def job(a):
    tests = parse_plan(a.plan)
    actions = deploy_initramfs(a)
    qdl = {"namespace": "target", "method": "qdl",
           "firehose_program": a.firehose, "rawprogram": a.rawprogram,
           "patch": a.patch, "storage": a.storage}
    if a.ramdump:
        qdl.update({"debug": True, "ramdump": True, "ramdump_timeout": 1800})
    qdl["timeout"] = {"minutes": a.qdl_minutes}
    actions.append({"boot": qdl})
    actions.append(login_boot(a))
    actions.append({"test": {"namespace": "target",
                             "timeout": {"minutes": a.test_minutes},
                             "definitions": definitions(a, tests)}})
    return {
        "device_type": a.device_type,
        "job_name": a.job_name,
        "priority": "medium",
        "visibility": "public",
        "timeouts": {"job": {"minutes": a.job_minutes},
                     "connection": {"minutes": 5}},
        "context": {"test_character_delay": 10},
        "actions": actions,
    }


# YAML plain scalars must not start with @ or % or end with a colon.
PLAIN = re.compile(r"^[A-Za-z0-9_./+-][A-Za-z0-9_./@%+:-]*(?<!:)$")
RESERVED = {"y", "n", "yes", "no", "on", "off", "true", "false", "null", "~"}


def scalar(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    s = str(v)
    if PLAIN.match(s) and s.lower() not in RESERVED and not re.match(r"^[-+.0-9]", s):
        return s
    return json.dumps(s)


def emit(v, indent=0):
    """Block-style YAML for dicts, lists and scalars (JSON-quoted strings)."""
    pad = "  " * indent
    out = []
    if isinstance(v, dict):
        for k, x in v.items():
            if isinstance(x, (dict, list)) and x:
                out.append("%s%s:" % (pad, scalar(k)))
                out.extend(emit(x, indent + (0 if isinstance(x, list) else 1)))
            else:
                out.append("%s%s: %s" % (pad, scalar(k), scalar(x) if x != {} else "{}"))
    elif isinstance(v, list):
        for x in v:
            if isinstance(x, (dict, list)) and x:
                sub = emit(x, indent + 1)
                out.append("%s- %s" % (pad, sub[0].lstrip()))
                out.extend(sub[1:])
            else:
                out.append("%s- %s" % (pad, scalar(x)))
    return out


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--device-type", required=True)
    p.add_argument("--job-name", required=True)
    p.add_argument("--plan", required=True)
    p.add_argument("--test-repo", required=True)
    p.add_argument("--test-branch", required=True)
    p.add_argument("--flash-name", required=True, help="flash tarball file name")
    p.add_argument("--uki-cmdline", required=True, help="kernel command line")
    p.add_argument("--uki-dtb", required=True, help="DTB file name in the ingredients")
    p.add_argument("--efi-size", default="512M", help="efi.bin size")
    p.add_argument("--firehose", default="prog_firehose_ddr.elf")
    p.add_argument("--rawprogram", required=True)
    p.add_argument("--patch", required=True)
    p.add_argument("--storage", required=True)
    p.add_argument("--ramdump", action="store_true", help="qdl debug and ramdump collection")
    p.add_argument("--login-prompt", default="buildroot login:")
    p.add_argument("--prompts", default=r"'\n# '",
                   help="shell prompts after login, as shell words")
    p.add_argument("--job-minutes", type=int, default=60)
    p.add_argument("--download-minutes", type=int, default=15)
    p.add_argument("--deploy-minutes", type=int, default=25)
    p.add_argument("--qdl-minutes", type=int, default=15)
    p.add_argument("--login-minutes", type=int, default=15)
    p.add_argument("--test-minutes", type=int, default=30)
    p.add_argument("-o", "--output", required=True)
    a = p.parse_args(argv)
    a.prompt = shlex.split(a.prompts)
    if not a.prompt:
        p.error("--prompts: no prompt")
    text = "\n".join(emit(job(a))) + "\n"
    with open(a.output, "w") as f:
        f.write(text)


if __name__ == "__main__":
    sys.exit(main())
