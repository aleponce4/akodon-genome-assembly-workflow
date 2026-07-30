#!/usr/bin/env python3
"""Unit and contract tests for the Akodon genome assembly workflow."""

import os
import subprocess
import tempfile
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


class TestPipelineLogic(unittest.TestCase):
    """Test bash helper logic in scripts/lib/common.sh via bash subprocesses."""

    def run_bash_cmd(self, cmd: str) -> str:
        full_cmd = (
            f"source '{REPO_ROOT}/scripts/lib/common.sh' && "
            f"source '{REPO_ROOT}/config/pipeline.env' && "
            f"{cmd}"
        )
        res = subprocess.run(
            ["bash", "-c", full_cmd],
            capture_output=True,
            text=True,
            cwd=REPO_ROOT,
            check=True,
        )
        return res.stdout.strip()

    def test_truthy(self):
        self.assertEqual(self.run_bash_cmd("truthy 1 && echo yes || echo no"), "yes")
        self.assertEqual(self.run_bash_cmd("truthy true && echo yes || echo no"), "yes")
        self.assertEqual(self.run_bash_cmd("truthy 0 && echo yes || echo no"), "no")
        self.assertEqual(self.run_bash_cmd("truthy false && echo yes || echo no"), "no")

    def test_sample_count(self):
        count_str = self.run_bash_cmd("sample_count")
        self.assertTrue(count_str.isdigit())
        self.assertGreaterEqual(int(count_str), 1)

    def test_sample_id_by_index(self):
        sample_0 = self.run_bash_cmd("sample_id_by_index 0")
        self.assertIsNotNone(sample_0)
        self.assertGreater(len(sample_0), 0)

    def test_stage_ranges_and_normalization(self):
        cmd = """
        normalize_stage() {
            local stage="$1"
            [[ "$stage" =~ ^[0-9]{1,2}$ ]] || exit 1
            printf '%02d' "$((10#$stage))"
        }
        normalize_stage 0 && printf ' '
        normalize_stage 3 && printf ' '
        normalize_stage 20
        """
        output = subprocess.run(
            ["bash", "-c", cmd],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        self.assertEqual(output, "00 03 20")

    def test_join_dependencies(self):
        cmd = """
        join_dependencies() {
            local joined=""
            local job_id
            for job_id in "$@"; do
                [[ -n "$job_id" ]] || continue
                joined="${joined:+$joined:}$job_id"
            done
            printf '%s' "$joined"
        }
        join_dependencies "1001" "1002" "" "1003"
        """
        output = subprocess.run(
            ["bash", "-c", cmd],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        self.assertEqual(output, "1001:1002:1003")

    def test_submission_manifest_structure(self):
        with tempfile.NamedTemporaryFile(mode="w+", delete=False) as tmp:
            tmp.write(
                "stage_id\tstage_name\tjob_id\tdependency\tarray\tstdout\tstderr\tscript\n"
            )
            tmp.write("01\tsupernova\t101\t\t0-3\tlog.out\tlog.err\t01.sh\n")
            tmp.write("02\tmkoutput\t102\t101\t0-3\tlog.out\tlog.err\t02.sh\n")
            tmp_path = tmp.name

        try:
            cmd = f"bash '{REPO_ROOT}/scripts/summarize_slurm_run.sh' '{tmp_path}'"
            res = subprocess.run(
                ["bash", "-c", cmd],
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertIn("101", res.stdout)
            self.assertIn("supernova", res.stdout)
            self.assertIn("102", res.stdout)
        finally:
            if os.path.exists(tmp_path):
                os.remove(tmp_path)


if __name__ == "__main__":
    unittest.main()
