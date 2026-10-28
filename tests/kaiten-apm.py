#!/usr/bin/env python3
"""Offline regression checks for the dual Claude/APM Kaiten package."""
from pathlib import Path
import json
import shutil
import tempfile
import unittest

from apm_cli.integration.command_integrator import CommandIntegrator
from apm_cli.models.validation import PackageType, detect_package_type, validate_apm_package

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "integrations/kaiten"


class KaitenAPMTests(unittest.TestCase):
    def setUp(self):
        self.scratch = Path(tempfile.mkdtemp(prefix="kaiten-apm-test-"))
        # APM materializes internal symlinks when copying a Git subdirectory.
        # Select package inputs explicitly; never copy environment/config files.
        self.package = self.scratch / "package"
        self.package.mkdir()
        for name in ("commands", ".claude-plugin", ".apm"):
            shutil.copytree(SOURCE / name, self.package / name, symlinks=False)
        shutil.copy2(SOURCE / "apm.yml", self.package / "apm.yml")
        # Retain small fixtures for inspection; no permanent cleanup is needed.

    def test_apm_resolves_full_hub_meta_reference(self):
        self.assertEqual(detect_package_type(self.package)[0], PackageType.APM_PACKAGE)
        result = validate_apm_package(self.package)
        self.assertTrue(result.is_valid, result.errors)
        dependencies = result.package.get_apm_dependencies()
        self.assertEqual(len(dependencies), 1)
        dependency = dependencies[0]
        self.assertEqual(dependency.repo_url, "dodobrands/ai-hub")
        self.assertEqual(dependency.virtual_path, "integrations/hub-meta")
        self.assertEqual(dependency.reference, "main")

    def test_every_command_is_exported_without_a_second_source_copy(self):
        source_commands = {p.stem: p for p in (SOURCE / "commands").glob("*.md")}
        exported = CommandIntegrator().find_prompt_files(self.package)
        self.assertTrue(source_commands)
        self.assertEqual({p.name.removesuffix(".prompt.md") for p in exported}, set(source_commands))
        for deployed in exported:
            name = deployed.name.removesuffix(".prompt.md")
            alias = SOURCE / ".apm/prompts" / deployed.name
            self.assertTrue(alias.is_symlink(), str(alias))
            self.assertEqual(alias.resolve(), source_commands[name].resolve())
            self.assertEqual(deployed.read_bytes(), source_commands[name].read_bytes())

    def test_versions_and_claude_dependency_remain_consistent(self):
        manifest = json.loads((SOURCE / ".claude-plugin/plugin.json").read_text())
        self.assertEqual(manifest["dependencies"], ["hub-meta"])
        package = validate_apm_package(self.package).package
        catalog = json.loads((ROOT / ".claude-plugin/marketplace.json").read_text())
        entry = next(p for p in catalog["plugins"] if p["name"] == manifest["name"])
        self.assertEqual(package.name, manifest["name"])
        self.assertEqual(package.version, manifest["version"])
        self.assertEqual(package.version, entry["version"])

    def test_legacy_plugin_only_layout_reproduces_the_reported_apm_error(self):
        legacy = self.scratch / "legacy"
        legacy.mkdir()
        for name in ("commands", ".claude-plugin"):
            shutil.copytree(SOURCE / name, legacy / name)
        result = validate_apm_package(legacy)
        self.assertFalse(result.is_valid)
        self.assertTrue(any("Invalid APM dependency 'hub-meta'" in error for error in result.errors), result.errors)


if __name__ == "__main__":
    unittest.main()
