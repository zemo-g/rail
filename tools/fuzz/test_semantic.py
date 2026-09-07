"""Oracle hand calculations, fault injection, and reducer contract tests."""
import json
from pathlib import Path
import random
import sys
import tempfile
import unittest
from unittest import mock

import semantic as s


class ReferenceTests(unittest.TestCase):
    def test_signed_division_and_remainder(self):
        for a, b, q, r in [(-7, 3, -2, -1), (7, -3, -2, 1), (-7, -3, 2, -1), (7, 3, 2, 1)]:
            self.assertEqual(s.evaluate(["div", ["int", a], ["int", b]]), q)
            self.assertEqual(s.evaluate(["mod", ["int", a], ["int", b]]), r)

    def test_hand_calculated_controls(self):
        self.assertEqual([s.evaluate(e) for e in s.controls()], [42, -2, -1, 1, 12, 11, 7, 0])

    def test_domain_errors(self):
        for tree in [["div", ["int", 1], ["int", 0]], ["head", ["list"]],
                     ["var", "missing"], ["add", ["int", s.LIMIT], ["int", 1]],
                     ["call", ["int", 1], ["int", 2]]]:
            with self.assertRaises(s.DomainError):
                s.evaluate(tree)

    def test_fuel_and_determinism(self):
        with self.assertRaises(s.DomainError):
            s.evaluate(["int", 1], fuel=[0])
        a, b = random.Random(42), random.Random(42)
        self.assertEqual([s.generate(a, 3) for _ in range(100)], [s.generate(b, 3) for _ in range(100)])

    def test_position_rendering(self):
        tree = ["int", -7]
        rendered = {p: s.source(tree, p) for p in s.POSITIONS}
        self.assertEqual(len(set(rendered.values())), 4)
        self.assertIn("probe ignored = (0 - 7)", rendered["tail"])
        self.assertIn("show (0 - 7)", rendered["argument"])
        self.assertIn("let result = (0 - 7)", rendered["let"])
        self.assertIn("if (0 - 7) == (0 - 7)", rendered["comparison"])

    def test_campaign_keeps_second_failure(self):
        def run(keep_going):
            visited = []
            def check(tree):
                visited.append(tree)
                return s.Result("mismatch" if len(visited) in (1, 3) else "pass", "0\n", s.Process(0, "", ""))
            with mock.patch.object(sys, "argv", ["semantic.py", "--cases", "0"] + (["--keep-going"] if keep_going else [])), \
                 mock.patch.object(s, "Runner") as factory, \
                 mock.patch.object(s, "save_failure", return_value=Path("fixture")) as save, \
                 mock.patch("builtins.print"):
                factory.return_value.check.side_effect = check
                self.assertEqual(s.main(), 1)
                return len(visited), save.call_count
        self.assertEqual(run(False), (1, 1))
        self.assertEqual(run(True), (32, 2))


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="semantic-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.compiler = self.root / "compiler"

    def fake(self, body):
        self.compiler.write_text("#!" + sys.executable + "\n" + body)
        self.compiler.chmod(0o755)
        return s.Runner(self.compiler, self.root, timeout=1)

    def emitting(self, stdout, code=0, stderr=""):
        program = "#!" + sys.executable + "\nimport sys\nsys.stdout.write(" + repr(stdout) + ")\nsys.stderr.write(" + repr(stderr) + ")\nsys.exit(" + str(code) + ")\n"
        return self.fake("import pathlib, sys\np=pathlib.Path(sys.argv[2])\np.write_text(" + repr(program) + ")\np.chmod(0o755)\n")

    def test_missing_binary_is_failure_even_with_exit_zero(self):
        runner = self.fake("raise SystemExit(0)\n")
        self.assertEqual(runner.check(["int", 42]).kind, "compile_error")

    def test_exit_and_full_output(self):
        for out, code, err, kind in [("42\n", 0, "", "pass"), ("42\n", 7, "", "runtime_error"),
                                      ("42\nwrong\n", 0, "", "mismatch"), ("42\n", 0, "error", "mismatch")]:
            self.assertEqual(self.emitting(out, code, err).check(["int", 42]).kind, kind)

    def test_timeout(self):
        runner = self.fake("import time\ntime.sleep(10)\n")
        runner.timeout = 0.1
        self.assertEqual(runner.check(["int", 42]).kind, "compile_timeout")

    def test_comparison_expected_result(self):
        for value in (-7, 0, 7):
            runner = self.emitting("1\n")
            runner.position = "comparison"
            self.assertEqual(runner.check(["int", value]).kind, "pass")
        runner = self.emitting("0\n")
        runner.position = "comparison"
        self.assertEqual(runner.check(["int", 7]).kind, "mismatch")

    def test_reducer_and_saved_replay(self):
        runner = self.emitting("999\n")
        runner.position = "tail"
        original = ["add", ["mul", ["int", 8], ["int", 9]], ["int", 3]]
        result = runner.check(original)
        folder = s.save_failure(self.root / "repros", original, result, runner, 42, 0, 20)
        record = json.loads((folder / "case.json").read_text())
        self.assertLess(s.complexity(record["tree"]), s.complexity(original))
        self.assertEqual(runner.check(record["tree"]).kind, "mismatch")
        self.assertTrue(record["stable"])
        self.assertEqual(record["position"], "tail")
        self.assertEqual((folder / "minimal.rail").read_text(), s.source(record["tree"], "tail"))
        # The reducer must not turn a runtime failure into an output mismatch.
        reduced, _ = s.minimize(original, runner, "runtime_error", 10)
        self.assertEqual(reduced, original)
        argv = [sys.executable, str(Path(s.__file__).resolve()), "--compiler", str(self.compiler),
                "--repo", str(self.root), "--replay", str(folder / "case.json")]
        self.assertEqual(s.execute(argv, self.root, 10).code, 1)
        # Simulate a repaired compiler and use the public CLI to replay the case.
        self.emitting(str(s.evaluate(record["tree"])) + "\n")
        self.assertEqual(s.execute(argv, self.root, 10).code, 0)


if __name__ == "__main__":
    unittest.main()
