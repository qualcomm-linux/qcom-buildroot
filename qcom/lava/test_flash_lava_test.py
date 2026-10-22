#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Unit tests of flash-lava-test.py: python3 -m unittest discover qcom/lava

PyYAML, where installed, parses the jobs back; without it the YAML checks
are skipped and the job structure is checked before emitting.
"""
import importlib.util
import os
import re
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("flt", os.path.join(HERE, "flash-lava-test.py"))
flt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(flt)

try:
    import yaml
except ImportError:
    yaml = None

class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def plan(self, text):
        path = os.path.join(self.tmp.name, "plan")
        with open(path, "w") as f:
            f.write(text)
        return path

    def run_gen(self, plan, *extra):
        out = os.path.join(self.tmp.name, "job.yaml")
        args = ["--device-type", "dt", "--job-name", "jn", "--plan", plan,
                "--test-repo", "https://example.org/td.git", "--test-branch", "b",
                "--rawprogram", "rawprogram0.xml rawprogram1.xml", "--patch", "patch0.xml",
                "--storage", "emmc", "-o", out] + list(extra)
        flt.main(args)
        with open(out) as f:
            text = f.read()
        return text, (yaml.safe_load(text) if yaml else None)

    def initramfs(self, plan, *extra):
        return self.run_gen(plan, "--flash-name", "b-flash.qcomflash.tar.gz",
                            "--uki-cmdline", "console=ttyMSM0,115200 earlycon",
                            "--uki-dtb", "b-el2.dtb", *extra)


class PlanTest(Base):
    def test_parse(self):
        p = self.plan("# comment\n"
                      "a  path/a.yaml\n"
                      "b path/b.yaml X=1 Y=\"two words\"  # trailing\n")
        self.assertEqual(flt.parse_plan(p), [("a", "path/a.yaml", {}),
                                             ("b", "path/b.yaml", {"X": "1", "Y": "two words"})])

    def test_errors(self):
        for text in ["a\n", "a p.yaml NOEQUALS\n", "a p.yaml 'open\n", "# empty\n"]:
            with self.subTest(text=text):
                with self.assertRaises(SystemExit):
                    flt.parse_plan(self.plan(text))


@unittest.skipUnless(yaml, "PyYAML not installed")
class JobTest(Base):
    def test_initramfs(self):
        _, j = self.initramfs(self.plan("t automated/t.yaml K=v\n"), "--ramdump")
        self.assertEqual(j["visibility"], "public")
        acts = [list(a)[0] for a in j["actions"]]
        self.assertEqual(acts, ["deploy", "deploy", "boot", "boot", "test"])
        dl = j["actions"][0]["deploy"]
        self.assertEqual(dl["to"], "downloads")
        self.assertEqual(dl["images"]["flash"]["headers"]["Authorization"], "<FLASH_TOKEN>")
        self.assertEqual(dl["images"]["ingredients"]["url"], "<INGREDIENTS_URL>")
        steps = dl["postprocess"]["docker"]["steps"]
        self.assertIn("--cmdline='console=ttyMSM0,115200 earlycon'", " ".join(steps))
        self.assertIn("--devicetree=ingredients/b-el2.dtb", " ".join(steps))
        self.assertEqual(j["actions"][1]["deploy"]["qcomflash"]["url"],
                         "downloads://b-flash-ukified.qcomflash.tar.gz")
        qdl = j["actions"][2]["boot"]
        self.assertTrue(qdl["ramdump"])
        self.assertEqual(qdl["rawprogram"], "rawprogram0.xml rawprogram1.xml")
        login = j["actions"][3]["boot"]
        self.assertNotIn("reset", login)
        self.assertNotIn("login_commands", login["auto_login"])
        self.assertEqual(login["prompts"], ["\\n# "])
        d = j["actions"][4]["test"]["definitions"][0]
        self.assertEqual(d, {"name": "t", "from": "git", "repository": "https://example.org/td.git",
                             "branch": "b", "path": "automated/t.yaml", "parameters": {"K": "v"}})

    def test_yaml_quoting(self):
        text, j = self.initramfs(self.plan("t t.yaml A=yes B=010 C='a: b' D=\"x # y\" "
                                           "E=@x F=%x G=login:\n"))
        self.assertEqual(j["actions"][4]["test"]["definitions"][0]["parameters"],
                         {"A": "yes", "B": "010", "C": "a: b", "D": "x # y",
                          "E": "@x", "F": "%x", "G": "login:"})


class OptionTest(Base):
    def test_initramfs_options(self):
        with self.assertRaises(SystemExit):
            self.run_gen(self.plan("t t.yaml\n"))


if __name__ == "__main__":
    unittest.main()
