"""Unit tests for the Jinja in macros/ and tests/generic/.

What this covers and what it does not, because the gap matters:

`dbt parse` proves every macro exists, parses, and is called with arguments
that resolve. It says nothing about the SQL that comes out. `dbt compile`
does, and opens a BigQuery connection to do it, so it cannot run here.

These tests render each macro in a bare Jinja environment and assert on the
text. They catch a flipped comparison, a dropped cast, a changed interval, an
argument that stopped being used, and the off-by-one between
incremental_window() and partition_window() that would otherwise read a day
the models never write. They do not catch BigQuery rejecting the result.
Nothing here opens a connection, reads a credential, or needs a warehouse.

The loader rewrites `{% test x %}` into `{% macro test_x %}` before handing
the file to Jinja, which is what dbt itself does with its TestExtension: a
generic test is a macro with a reserved name. `return()` raises, also as dbt
implements it, so a macro that returns a list returns a Python list here too.
"""

from __future__ import annotations

import re
from pathlib import Path

import jinja2
import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
MACRO_DIR = REPO_ROOT / "macros"
GENERIC_TEST_DIR = REPO_ROOT / "tests" / "generic"
MODEL_DIR = REPO_ROOT / "models"

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


def _environment() -> jinja2.Environment:
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


def _load(path: Path) -> jinja2.Template:
    source = path.read_text(encoding="utf-8")
    source = TEST_TAG.sub(r"{%\1 macro test_", source)
    source = ENDTEST_TAG.sub(r"{%\1 endmacro \2%}", source)
    return _environment().from_string(source)


def call(filename: str, macro_name: str, *args: object, **kwargs: object) -> object:
    """Render one macro. Returns squashed SQL text, or the returned object."""
    directory = GENERIC_TEST_DIR if macro_name.startswith("test_") else MACRO_DIR
    template = _load(directory / filename)
    macro = getattr(template.module, macro_name)
    try:
        rendered = macro(*args, **kwargs)
    except MacroReturn as returned:
        return returned.value
    return " ".join(str(rendered).split())


def interval_days(predicate: str) -> int:
    """Pull N out of `... interval N day`."""
    match = re.search(r"interval (-?\d+) day", predicate)
    assert match is not None, f"no interval found in {predicate!r}"
    return int(match.group(1))


# --------------------------------------------------------------------------
# incremental_window
# --------------------------------------------------------------------------


def test_incremental_window_defaults_to_the_project_variable() -> None:
    assert call("incremental_window.sql", "incremental_window", "event_date") == (
        "event_date >= date_sub(current_date(), interval 2 day)"
    )


def test_incremental_window_counts_today_as_one_of_the_days() -> None:
    # days=1 must mean today only, so the subtraction is zero and not one.
    rendered = str(call("incremental_window.sql", "incremental_window", "event_date", 1))
    assert interval_days(rendered) == 0


def test_incremental_window_widens_for_the_models_that_read_more_than_they_write() -> None:
    predicate = str(call("incremental_window.sql", "incremental_window", "event_date", 31))
    assert interval_days(predicate) == 30


def test_incremental_window_qualifies_whatever_column_it_is_given() -> None:
    predicate = str(call("incremental_window.sql", "incremental_window", "w.event_date"))
    assert predicate.startswith("w.event_date >=")


@pytest.mark.parametrize("bad", [0, -1, "3"])
def test_incremental_window_refuses_a_lookback_that_is_not_a_positive_number(
    bad: object,
) -> None:
    with pytest.raises(CompilerError):
        call("incremental_window.sql", "incremental_window", "event_date", bad)


# --------------------------------------------------------------------------
# partition_window
# --------------------------------------------------------------------------


def test_partition_window_lists_one_partition_per_day() -> None:
    assert call("partition_window.sql", "partition_window") == [
        "current_date()",
        "date_sub(current_date(), interval 1 day)",
        "date_sub(current_date(), interval 2 day)",
    ]


def test_partition_window_of_one_day_is_just_today() -> None:
    assert call("partition_window.sql", "partition_window", 1) == ["current_date()"]


def test_partition_window_never_repeats_a_partition() -> None:
    partitions = call("partition_window.sql", "partition_window", 14)
    assert isinstance(partitions, list)
    assert len(partitions) == 14
    assert len(set(partitions)) == 14


@pytest.mark.parametrize("bad", [0, -5, "7"])
def test_partition_window_refuses_a_bad_lookback(bad: object) -> None:
    with pytest.raises(CompilerError):
        call("partition_window.sql", "partition_window", bad)


@pytest.mark.parametrize("days", [1, 3, 7, 31])
def test_the_filter_and_the_partition_list_cover_the_same_span(days: int) -> None:
    """The one that costs money if it drifts.

    insert_overwrite replaces the partitions partition_window() names. The
    models read the rows incremental_window() admits. If the filter reaches
    back further than the list, the extra day is read, aggregated and thrown
    away, and nothing anywhere fails.
    """
    predicate = str(call("incremental_window.sql", "incremental_window", "event_date", days))
    partitions = call("partition_window.sql", "partition_window", days)
    assert isinstance(partitions, list)
    assert interval_days(predicate) == len(partitions) - 1


# --------------------------------------------------------------------------
# money
# --------------------------------------------------------------------------


def test_money_rounds_inside_the_cast() -> None:
    assert call("money.sql", "money", "amount") == "cast(round(amount, 2) as numeric)"


def test_money_rounds_before_casting_and_not_after() -> None:
    rendered = str(call("money.sql", "money", "t.amount"))
    assert rendered.index("round(") < rendered.index("as numeric")


def test_money_scale_is_configurable() -> None:
    assert call("money.sql", "money", "fx_rate", 6) == "cast(round(fx_rate, 6) as numeric)"


def test_money_wraps_an_aggregate_rather_than_a_column_name() -> None:
    assert call("money.sql", "money", "sum(amount)") == "cast(round(sum(amount), 2) as numeric)"


# --------------------------------------------------------------------------
# to_minor_units
# --------------------------------------------------------------------------


def test_to_minor_units_scales_by_the_currencys_own_exponent() -> None:
    assert call("to_minor_units.sql", "to_minor_units", "t.amount", "c.minor_units") == (
        "cast(round(t.amount * pow(10, c.minor_units)) as int64)"
    )


def test_to_minor_units_rounds_explicitly_rather_than_relying_on_the_cast() -> None:
    rendered = str(call("to_minor_units.sql", "to_minor_units", "amount", "2"))
    assert rendered.index("round(") < rendered.index("as int64")


def test_to_minor_units_does_not_hardcode_a_two_decimal_assumption() -> None:
    rendered = str(call("to_minor_units.sql", "to_minor_units", "amount", "c.minor_units"))
    assert "pow(10, 2)" not in rendered
    assert "* 100" not in rendered


# --------------------------------------------------------------------------
# generic tests
# --------------------------------------------------------------------------


def test_not_in_future_compares_dates_not_timestamps() -> None:
    rendered = str(call("not_in_future.sql", "test_not_in_future", "my_model", "occurred_at"))
    assert "cast(occurred_at as date) > date_add(current_date(), interval 0 day)" in rendered


def test_not_in_future_grace_period_moves_the_boundary() -> None:
    rendered = str(call("not_in_future.sql", "test_not_in_future", "my_model", "event_date", 1))
    assert interval_days(rendered) == 1


def test_mutually_exclusive_flags_requires_exactly_one_true() -> None:
    rendered = str(
        call(
            "mutually_exclusive_flags.sql",
            "test_mutually_exclusive_flags",
            "my_model",
            ["is_a", "is_b", "is_c"],
        )
    )
    assert "if(is_a, 1, 0) + if(is_b, 1, 0) + if(is_c, 1, 0)" in rendered
    assert ") != 1" in rendered
    assert "group by 1, 2, 3" in rendered


def test_mutually_exclusive_flags_never_casts_a_boolean() -> None:
    # cast(null as int64) is null, the sum is null, null != 1 is null, and the
    # offending row is not returned. if() maps null to 0 and the row fails.
    rendered = str(
        call(
            "mutually_exclusive_flags.sql",
            "test_mutually_exclusive_flags",
            "my_model",
            ["is_a", "is_b"],
        )
    )
    assert "cast(" not in rendered


def test_mutually_exclusive_flags_refuses_a_single_flag() -> None:
    with pytest.raises(CompilerError):
        call(
            "mutually_exclusive_flags.sql",
            "test_mutually_exclusive_flags",
            "my_model",
            ["is_a"],
        )


def test_reconciles_with_full_outer_joins_so_a_missing_group_fails() -> None:
    rendered = str(
        call(
            "reconciles_with.sql",
            "test_reconciles_with",
            "my_model",
            "total_amount",
            "other_model",
            "amount",
            ["event_date", "currency_code"],
        )
    )
    assert "full outer join" in rendered
    assert "m.event_date = p.event_date and m.currency_code = p.currency_code" in rendered
    assert "m.side_total is null" in rendered
    assert "p.side_total is null" in rendered


def test_reconciles_with_compares_an_absolute_difference_to_the_tolerance() -> None:
    rendered = str(
        call(
            "reconciles_with.sql",
            "test_reconciles_with",
            "my_model",
            "total_amount",
            "other_model",
            "amount",
            ["event_date"],
            0.01,
        )
    )
    assert "abs(m.side_total - p.side_total) > 0.01" in rendered


def test_reconciles_with_needs_something_to_group_by() -> None:
    with pytest.raises(CompilerError):
        call(
            "reconciles_with.sql",
            "test_reconciles_with",
            "my_model",
            "total_amount",
            "other_model",
            "amount",
            [],
        )


def test_monotonic_within_group_compares_each_row_with_its_predecessor() -> None:
    rendered = str(
        call(
            "monotonic_within_group.sql",
            "test_monotonic_within_group",
            "my_model",
            "txn_seq_in_day",
            ["account_id", "event_date"],
            "occurred_at",
        )
    )
    assert (
        "lag(txn_seq_in_day) over ( partition by account_id, event_date "
        "order by occurred_at )" in rendered
    )
    assert "previous_value is not null" in rendered
    assert "current_value <= previous_value" in rendered


def test_monotonic_within_group_allows_a_repeat_when_not_strict() -> None:
    rendered = str(
        call(
            "monotonic_within_group.sql",
            "test_monotonic_within_group",
            "my_model",
            "running_total",
            ["account_id"],
            "occurred_at",
            False,
        )
    )
    assert "current_value < previous_value" in rendered
    assert "<=" not in rendered


# --------------------------------------------------------------------------
# conventions the project relies on
# --------------------------------------------------------------------------


def test_every_macro_file_defines_the_macro_named_after_it() -> None:
    for path in sorted(MACRO_DIR.glob("*.sql")):
        template = _load(path)
        assert hasattr(template.module, path.stem), (
            f"{path.name} does not define a macro called {path.stem}"
        )


def test_every_generic_test_file_defines_the_test_named_after_it() -> None:
    for path in sorted(GENERIC_TEST_DIR.glob("*.sql")):
        template = _load(path)
        assert hasattr(template.module, f"test_{path.stem}"), (
            f"{path.name} does not define a test called {path.stem}"
        )


def test_every_generic_test_filters_instead_of_returning_everything() -> None:
    # A generic test fails on the rows it returns. One with no predicate
    # returns the whole relation and fails permanently; one that returns
    # nothing passes permanently. Both are useless in the same way.
    for path in sorted(GENERIC_TEST_DIR.glob("*.sql")):
        body = path.read_text(encoding="utf-8")
        assert "where" in body, f"{path.name} has no where clause"


def test_every_incremental_model_filters_on_the_shared_window() -> None:
    # The most expensive mistake available in this repo: an incremental model
    # that reads the whole fact table every run. It produces correct numbers,
    # so only the query cost says anything is wrong.
    for path in sorted(MODEL_DIR.rglob("*.sql")):
        body = path.read_text(encoding="utf-8")
        if "materialized='incremental'" not in body:
            continue
        assert "incremental_window(" in body, f"{path.name} does not filter its input"
        assert "partitions=partition_window(" in body, (
            f"{path.name} does not declare the partitions it replaces"
        )
        assert "incremental_strategy='insert_overwrite'" in body, (
            f"{path.name} is incremental but not insert_overwrite"
        )
