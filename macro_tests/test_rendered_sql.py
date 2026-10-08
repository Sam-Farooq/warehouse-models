"""Render every model and analysis, then parse the result as BigQuery SQL.

The gap this fills: `dbt parse` resolves every ref, source, seed, macro and
test and type-checks every config, and says nothing about the SQL text those
things produce. `dbt compile` would say something about it, and asks the
adapter for relation metadata to do so, which needs credentials this project
does not have on a public runner.

So each file is rendered here in the same bare Jinja environment the macro
tests use, with the real macros from macros/ loaded, and the four dbt
functions that genuinely need a warehouse behind them replaced by stubs:
`ref` and `source` become table identifiers, `config` renders to nothing, and
`is_incremental()` is set per case so that both branches of every incremental
model get rendered. The output goes to sqlglot's BigQuery parser.

What that catches: an unbalanced parenthesis, a dropped comma, a window frame
or a QUALIFY that does not parse, a macro whose output is not a valid
expression where it is used, and the same set of mistakes in the incremental
branch, which is the half a reader of the file never sees.

What it does not catch, stated plainly because the distinction is the whole
point of this file: sqlglot's BigQuery parser is not BigQuery. The table names
are stubs, nothing here knows the real column list, nothing is type-checked,
and a statement this accepts can still be rejected by the warehouse or return
the wrong answer. The models in this repo have never been executed against
BigQuery. This is a syntax gate.
"""

from __future__ import annotations

from pathlib import Path

import jinja2
import pytest
import sqlglot
from dbt_jinja import ANALYSIS_DIR, MACRO_DIR, MODEL_DIR, MacroReturn, environment

SQL_FILES = sorted(MODEL_DIR.rglob("*.sql")) + sorted(ANALYSIS_DIR.glob("*.sql"))

# Read from the files rather than listed, so a new incremental model is
# covered by the window assertions below without anyone remembering to add it.
INCREMENTAL_FILES = [
    path for path in SQL_FILES if "materialized='incremental'" in path.read_text(encoding="utf-8")
]

# 3 reprocess days counted inclusive of today, so the predicate reaches back
# two. Spelled out rather than computed, because a test that derives its
# expectation from the same macro it is testing asserts nothing.
WRITE_WINDOW_PREDICATE = "date_sub(current_date(), interval 2 day)"

# The two models that read wider than they write, and what each one reads.
# int_transactions_sequenced needs the previous transaction, which can be
# yesterday's; fct_account_currency_daily needs its 28 day trailing baseline.
WIDE_READERS = {
    "int_transactions_sequenced.sql": "date_sub(current_date(), interval 3 day)",
    "fct_account_currency_daily.sql": "date_sub(current_date(), interval 30 day)",
}


def _macros(env: jinja2.Environment) -> dict[str, object]:
    """Every macro in macros/, wrapped so that return() behaves as dbt's does.

    dbt catches the exception return() raises at the macro call boundary. Here
    the caller is a model, so the wrapper has to catch it in the same place:
    without this, partition_window() inside a config block raises instead of
    handing back its list of dates.
    """
    namespace: dict[str, object] = {}
    for path in sorted(MACRO_DIR.glob("*.sql")):
        module = env.from_string(path.read_text(encoding="utf-8")).module
        for name in dir(module):
            candidate = getattr(module, name)
            if isinstance(candidate, jinja2.runtime.Macro):
                namespace[name] = _catching_return(candidate)
    return namespace


def _catching_return(macro: jinja2.runtime.Macro):
    def call(*args: object, **kwargs: object) -> object:
        try:
            return macro(*args, **kwargs)
        except MacroReturn as returned:
            return returned.value

    return call


def render(path: Path, incremental: bool) -> str:
    env = environment()
    env.globals.update(_macros(env))
    # The stubs. A dataset-qualified identifier keeps the rendered text
    # parseable; it is not the relation the model actually reads.
    env.globals["ref"] = lambda name: f"`parse_check.marts.{name}`"
    env.globals["source"] = lambda source_name, table: f"`parse_check.{source_name}.{table}`"
    env.globals["this"] = "`parse_check.marts.target`"
    env.globals["config"] = lambda **kwargs: ""
    env.globals["is_incremental"] = lambda: incremental
    return env.from_string(path.read_text(encoding="utf-8")).render()


def _cases() -> list[tuple[Path, bool]]:
    cases = []
    for path in SQL_FILES:
        cases.append((path, False))
        if path in INCREMENTAL_FILES:
            cases.append((path, True))
    return cases


def _case_id(case: tuple[Path, bool]) -> str:
    path, incremental = case
    return f"{path.stem}-{'incremental' if incremental else 'full_refresh'}"


@pytest.mark.parametrize("case", _cases(), ids=_case_id)
def test_rendered_sql_parses_as_bigquery(case: tuple[Path, bool]) -> None:
    path, incremental = case
    sql = render(path, incremental)
    parsed = sqlglot.parse_one(sql, dialect="bigquery")
    assert isinstance(parsed, sqlglot.exp.Select), (
        f"{path.name} did not render to a single SELECT statement"
    )
    # Generate and re-parse. A tree that cannot survive a round trip through
    # the dialect usually means the first parse put something in the wrong
    # place rather than failing outright.
    sqlglot.parse_one(parsed.sql(dialect="bigquery"), dialect="bigquery")


@pytest.mark.parametrize("path", INCREMENTAL_FILES, ids=lambda path: path.stem)
def test_incremental_branch_filters_and_full_refresh_does_not(path: Path) -> None:
    assert WRITE_WINDOW_PREDICATE in render(path, incremental=True), (
        f"{path.name} renders no window predicate on an incremental run"
    )
    # A full refresh has to read everything. A stray predicate here would make
    # --full-refresh rebuild three days and silently drop the rest of history.
    assert WRITE_WINDOW_PREDICATE not in render(path, incremental=False), (
        f"{path.name} still filters on a full refresh"
    )


@pytest.mark.parametrize(("filename", "read_predicate"), sorted(WIDE_READERS.items()))
def test_the_wide_readers_render_both_windows(filename: str, read_predicate: str) -> None:
    # A window function cannot see a row the WHERE clause already removed, so
    # these two read more days than they write. If the wide predicate ever
    # collapses onto the write window, every number still looks plausible:
    # seconds_since_prev goes null at each account's first transaction of the
    # day, and the trailing average becomes an average over whatever survived.
    path = next(candidate for candidate in SQL_FILES if candidate.name == filename)
    sql = render(path, incremental=True)
    assert read_predicate in sql, f"{filename} no longer reads its wide window"
    assert WRITE_WINDOW_PREDICATE in sql, f"{filename} no longer writes the shared window"


def test_every_sql_file_in_the_project_is_rendered() -> None:
    # Guards the parametrize list itself. A glob that stops matching turns this
    # whole module into a suite that passes by checking nothing.
    assert len(SQL_FILES) == len(set(SQL_FILES))
    assert {path.name for path in _cases_paths()} == {path.name for path in SQL_FILES}
    assert len(SQL_FILES) >= 15, "fewer SQL files found than the project contains"
    assert len(INCREMENTAL_FILES) >= 5, "fewer incremental models found than exist"


def _cases_paths() -> list[Path]:
    return [path for path, _ in _cases()]
