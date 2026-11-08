"""The measure catches each small defect: drawn by Core Graphics (as the backend draws), each synthetic case must score
clearly worse against the MuPDF oracle than the floor (the unchanged page drawn by Core Graphics) does.

    clients/render/harness/test        (needs tectonic, mutool, swiftc)
"""

import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "synthetic"))
import cases  # noqa: E402
import measure  # noqa: E402


@pytest.fixture(scope="module")
def floor():
    return measure.compare(cases.renders("base")["mu"], cases.renders("base")["cg"])


def test_floor_is_small(floor):
    assert floor["bad"] <= 20, floor


def test_same_render_is_zero():
    p = cases.renders("base")["mu"]
    assert measure.compare(p, p)["bad"] == 0


@pytest.mark.parametrize("case", [c for c in cases.CASES if c != "base"])
def test_defect_beats_floor(case, floor):
    r = measure.compare(cases.renders("base")["mu"], cases.renders(case)["cg"])
    # clearly worse: past the floor plus the pass margin, and at least 3x the floor
    assert r["bad"] > floor["bad"] + measure.MARGIN and r["bad"] >= 3 * max(floor["bad"], 1), (case, r, floor)
    assert not measure.within_floor(r["bad"], floor["bad"])


@pytest.mark.parametrize("case", [c for c in cases.CASES if c != "base"])
def test_defect_seen_by_mupdf_too(case):
    """The same defect drawn by MuPDF (no antialiasing difference at all) is also caught."""
    r = measure.compare(cases.renders("base")["mu"], cases.renders(case)["mu"])
    assert r["bad"] > measure.MARGIN, (case, r)
