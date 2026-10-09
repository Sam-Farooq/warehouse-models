"""Every analysis is declared as an exposure, and declares exactly its inputs.

An exposure is only worth having if it is true. A stale one is worse than a
missing one: `dbt ls --select +exposure:*` answers either way, and the answer
from a stale exposure is wrong in the direction that matters, telling you a
model change is safe when it is not.

So rather than trusting the YAML to be maintained, this compares it against the
`ref()` calls in the analyses themselves. Adding an analysis, or adding a ref to
an existing one, fails here until the exposure is updated.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parent.parent
ANALYSES = sorted((ROOT / "analyses").glob("*.sql"))
REF = re.compile(r"ref\(\s*'([^']+)'\s*\)")


def refs_in(path: Path) -> set[str]:
    return set(REF.findall(path.read_text(encoding="utf-8")))


@pytest.fixture(scope="module")
def exposures() -> dict[str, dict]:
    raw = yaml.safe_load((ROOT / "models" / "_exposures.yml").read_text(encoding="utf-8"))
    return {e["name"]: e for e in raw["exposures"]}


def test_there_is_at_least_one_analysis_to_check():
    # Guards the whole file: a glob that matches nothing would make every
    # parametrised test below vacuously pass.
    assert ANALYSES, "no analyses found, so nothing here proves anything"


@pytest.mark.parametrize("path", ANALYSES, ids=lambda p: p.stem)
def test_every_analysis_has_an_exposure(path: Path, exposures):
    assert path.stem in exposures, (
        f"analyses/{path.name} has no exposure, so dbt cannot say what a column "
        f"rename in {sorted(refs_in(path))} would break"
    )


@pytest.mark.parametrize("path", ANALYSES, ids=lambda p: p.stem)
def test_an_exposure_declares_exactly_what_its_analysis_reads(path: Path, exposures):
    declared = {REF.search(d).group(1) for d in exposures[path.stem]["depends_on"]}
    actual = refs_in(path)
    assert declared == actual, (
        f"analyses/{path.name} reads {sorted(actual)} and its exposure declares {sorted(declared)}"
    )


def test_no_exposure_describes_an_analysis_that_is_gone(exposures):
    stems = {p.stem for p in ANALYSES}
    assert set(exposures) <= stems, f"exposures with no analysis: {sorted(set(exposures) - stems)}"


def test_every_exposure_names_an_owner_and_a_maturity(exposures):
    # Deliberately iterates the file rather than a list written here, so adding
    # an exposure cannot skip this check.
    assert exposures
    for name, e in exposures.items():
        assert e["owner"]["email"], f"{name} has no owner, which is a dead end when it breaks"
        assert e["maturity"] in {"low", "medium", "high"}, f"{name} has maturity {e['maturity']!r}"
        assert e["type"] == "analysis", f"{name} is type {e['type']!r}"
