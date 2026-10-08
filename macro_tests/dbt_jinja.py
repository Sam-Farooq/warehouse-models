"""A bare Jinja environment that renders this project's SQL the way dbt does.

Shared by the two test modules, because both of them need dbt's Jinja and
neither of them is allowed to need a warehouse.

Two pieces of dbt's behaviour are reimplemented here rather than imported.
`return()` raises, as dbt's own implementation does, and the macro caller
catches it, so a macro that returns a list returns a Python list here too.
And `{% test x %}` is rewritten into `{% macro test_x %}` before the file
reaches Jinja, which is what dbt's TestExtension does: a generic test is a
macro with a reserved name.

What is deliberately absent: an adapter, a connection, a credential, and the
dbt runtime. Everything in here is text in and text out.
"""

from __future__ import annotations

import re
from pathlib import Path

import jinja2

REPO_ROOT = Path(__file__).resolve().parent.parent
MACRO_DIR = REPO_ROOT / "macros"
GENERIC_TEST_DIR = REPO_ROOT / "tests" / "generic"
MODEL_DIR = REPO_ROOT / "models"
ANALYSIS_DIR = REPO_ROOT / "analyses"

# Mirrors the vars block in dbt_project.yml. Duplicated rather than parsed out
# of the YAML, so that a change to the project defaults shows up here as a
# failing test instead of as a silently different expectation.
PROJECT_VARS = {
    "reprocess_window_days": 3,
    "trailing_window_days": 28,
    "velocity_txn_per_hour": 6,
    "country_hop_seconds": 1800,
    "round_amount_floor": 5000,
}

TEST_TAG = re.compile(r"{%(-?)\s*test\s+")
ENDTEST_TAG = re.compile(r"{%(-?)\s*endtest\s*(-?)%}")


class MacroReturn(Exception):
    """What dbt's return() raises to carry a value out of a macro."""

    def __init__(self, value: object) -> None:
        super().__init__("macro returned a value")
        self.value = value


class CompilerError(Exception):
    """Stands in for dbt_common.exceptions.CompilationError."""


def _jinja_return(value: object) -> None:
    raise MacroReturn(value)


def _var(name: str, default: object = None) -> object:
    if name not in PROJECT_VARS and default is None:
        raise KeyError(f"var({name!r}) is not defined in PROJECT_VARS")
    return PROJECT_VARS.get(name, default)


class _Exceptions:
    @staticmethod
    def raise_compiler_error(message: str) -> None:
        raise CompilerError(message)


def environment() -> jinja2.Environment:
    env = jinja2.Environment(
        extensions=["jinja2.ext.do"],
        undefined=jinja2.StrictUndefined,
        autoescape=False,
        keep_trailing_newline=True,
    )
    env.globals["return"] = _jinja_return
    env.globals["var"] = _var
    env.globals["exceptions"] = _Exceptions()
    return env


def load(path: Path, env: jinja2.Environment | None = None) -> jinja2.Template:
    source = path.read_text(encoding="utf-8")
    source = TEST_TAG.sub(r"{%\1 macro test_", source)
    source = ENDTEST_TAG.sub(r"{%\1 endmacro \2%}", source)
    return (env or environment()).from_string(source)
