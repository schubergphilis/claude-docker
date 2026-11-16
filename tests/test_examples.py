"""The example settings under examples/ stay loadable and safe to copy."""

import json
import pathlib
import unittest

EXAMPLES = pathlib.Path(__file__).resolve().parent.parent / "examples"
RULE_LISTS = ("environment", "allow", "soft_deny", "hard_deny")


class ExamplesTest(unittest.TestCase):
    def test_every_example_is_a_json_object(self):
        paths = sorted(EXAMPLES.glob("*.json"))
        self.assertTrue(paths)
        for path in paths:
            with self.subTest(path=path.name):
                self.assertIsInstance(json.loads(path.read_text()), dict)

    def test_auto_mode_lists_keep_the_built_in_rules(self):
        # A list without "$defaults" replaces Claude Code's built-in rules for
        # that section, which would drop e.g. the data-exfiltration block.
        auto = json.loads((EXAMPLES / "settings.docker.auto-mode.json").read_text())["autoMode"]
        self.assertTrue(set(auto) & set(RULE_LISTS))
        for name in RULE_LISTS:
            if name in auto:
                with self.subTest(section=name):
                    self.assertEqual(auto[name][0], "$defaults")
                    self.assertGreater(len(auto[name]), 1)


if __name__ == "__main__":
    unittest.main()
