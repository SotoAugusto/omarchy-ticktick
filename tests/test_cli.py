#!/usr/bin/env python3
"""Regression tests for state-changing CLI operations."""

from datetime import date
from pathlib import Path
import runpy
import unittest


CLI_PATH = Path(__file__).resolve().parents[1] / "bin" / "omarchy-ticktick"


def load_cli():
    return runpy.run_path(str(CLI_PATH))


class RecurringCompletionTests(unittest.TestCase):
    def setUp(self):
        self.cli = load_cli()
        self.globals = self.cli["set_task_status"].__globals__
        self.dispatched = []
        self.queued = []

        def fake_batch_task(_session, add=None, update=None, delete=None):
            self.dispatched.append({
                "add": add or [],
                "update": update or [],
                "delete": delete or [],
            })
            return {}

        def fake_with_session(callback):
            session = {"token": "<REDACTED>"}
            return callback(session), session

        self.globals["batch_task"] = fake_batch_task
        self.globals["with_session"] = fake_with_session
        self.globals["now_api_time"] = lambda: "2026-09-02T12:00:00.000+0000"
        self.globals["queue_write"] = lambda *args: self.queued.append(args)
        self.globals["cached_task"] = lambda task_id: (_ for _ in ()).throw(
            self.cli["TickTickError"](f"Task {task_id} is not in the local cache; sync first")
        )

    def task(self, **fields):
        return {
            "id": "task-1",
            "projectId": "project-1",
            "status": self.cli["STATUS_TODO"],
            **fields,
        }

    def use_task(self, task):
        self.globals["cached_task"] = lambda _task_id: task
        self.globals["find_task"] = lambda _task_id, _session: task

    def test_recurring_markers_are_recognized(self):
        recurring = self.cli["is_recurring_task"]
        self.assertTrue(recurring({"repeatFlag": "RRULE:FREQ=DAILY"}))
        self.assertTrue(recurring({"repeatFrom": "2", "repeatFlag": ""}))
        self.assertTrue(recurring({"repeatTaskId": "series-1"}))
        self.assertTrue(recurring({"repeatFirstDate": "2026-09-02T08:00:00.000+0000"}))
        self.assertFalse(recurring({"repeatFrom": "0"}))
        self.assertFalse(recurring({"id": "plain"}))

    def recurring(self, **fields):
        defaults = {
            "repeatFlag": "RRULE:FREQ=DAILY;INTERVAL=1",
            "startDate": "2026-09-02T08:00:00.000+0000",
            "dueDate": "2026-09-02T09:00:00.000+0000",
            "timeZone": "UTC",
        }
        return self.task(**{**defaults, **fields})

    def test_online_recurring_completion_advances_the_series_in_one_batch(self):
        task = self.recurring()
        self.use_task(task)

        series = self.cli["set_task_status"](task["id"], self.cli["STATUS_DONE"])

        self.assertEqual(len(self.dispatched), 1)
        batch = self.dispatched[0]
        self.assertEqual(len(batch["add"]), 1)
        self.assertEqual(len(batch["update"]), 1)

        occurrence, updated = batch["add"][0], batch["update"][0]
        # The finished occurrence is a new record pointing back at the series.
        self.assertNotEqual(occurrence["id"], task["id"])
        self.assertEqual(occurrence["repeatTaskId"], task["id"])
        self.assertEqual(occurrence["status"], self.cli["STATUS_DONE"])
        self.assertIsNone(occurrence["repeatFlag"])
        # The series itself stays open, one day further on.
        self.assertIs(updated, series)
        self.assertEqual(updated["id"], task["id"])
        self.assertEqual(updated["status"], self.cli["STATUS_TODO"])
        self.assertIsNone(updated["completedTime"])
        self.assertEqual(updated["dueDate"], "2026-09-03T09:00:00.000+0000")
        self.assertEqual(updated["startDate"], "2026-09-03T08:00:00.000+0000")

    def test_completion_resets_per_occurrence_state(self):
        task = self.recurring(
            items=[{"id": "item-1", "title": "step", "status": 1, "completedTime": "x"}],
            progress=100,
        )
        self.use_task(task)

        series = self.cli["set_task_status"](task["id"], self.cli["STATUS_DONE"])
        occurrence = self.dispatched[0]["add"][0]

        self.assertEqual(series["items"][0]["status"], 0)
        self.assertIsNone(series["items"][0]["completedTime"])
        self.assertEqual(series["progress"], 0)
        # The occurrence keeps what was ticked, under its own item ids.
        self.assertEqual(occurrence["items"][0]["status"], 1)
        self.assertNotEqual(occurrence["items"][0]["id"], "item-1")

    def test_subtask_dates_travel_with_the_task(self):
        task = self.recurring(
            items=[{"id": "item-1", "title": "step", "startDate": "2026-09-02T08:00:00.000+0000"}]
        )
        self.use_task(task)

        series = self.cli["set_task_status"](task["id"], self.cli["STATUS_DONE"])

        self.assertEqual(series["items"][0]["startDate"], "2026-09-03T08:00:00.000+0000")

    def test_a_skipped_occurrence_is_not_rolled_back_onto(self):
        task = self.recurring(exDate=["2026-09-03T09:00:00.000+0000"])
        self.use_task(task)

        series = self.cli["set_task_status"](task["id"], self.cli["STATUS_DONE"])

        self.assertEqual(series["dueDate"], "2026-09-04T09:00:00.000+0000")

    def test_weekly_rule_advances_to_the_next_listed_weekday(self):
        # 2026-09-02 is a Wednesday; the rule also fires on Friday.
        task = self.recurring(repeatFlag="RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR")
        self.use_task(task)

        series = self.cli["set_task_status"](task["id"], self.cli["STATUS_DONE"])

        self.assertEqual(series["dueDate"], "2026-09-04T09:00:00.000+0000")

    def test_repeat_from_completion_counts_from_today(self):
        task = self.recurring(
            repeatFlag="RRULE:FREQ=WEEKLY;INTERVAL=2",
            repeatFrom="2",
            dueDate="2026-08-01T09:00:00.000+0000",
            startDate="2026-08-01T09:00:00.000+0000",
        )
        self.use_task(task)

        series = self.cli["set_task_status"](task["id"], self.cli["STATUS_DONE"])

        # Completed 2026-09-02, so the next one is two weeks after that day,
        # not two weeks after the due date it overshot.
        self.assertEqual(series["dueDate"], "2026-09-16T09:00:00.000+0000")

    def test_last_occurrence_of_a_counted_series_completes_plainly(self):
        task = self.recurring(repeatFlag="RRULE:FREQ=DAILY;INTERVAL=1;COUNT=1")
        self.use_task(task)

        completed = self.cli["set_task_status"](task["id"], self.cli["STATUS_DONE"])

        self.assertEqual(completed["status"], self.cli["STATUS_DONE"])
        self.assertEqual(self.dispatched[0]["add"], [])
        self.assertEqual(self.dispatched[0]["update"][0]["id"], task["id"])

    def test_counted_series_decrements_as_it_rolls_forward(self):
        task = self.recurring(repeatFlag="RRULE:FREQ=DAILY;INTERVAL=1;COUNT=3")
        self.use_task(task)

        series = self.cli["set_task_status"](task["id"], self.cli["STATUS_DONE"])

        self.assertEqual(series["repeatFlag"], "RRULE:FREQ=DAILY;INTERVAL=1;COUNT=2")

    def test_a_rule_past_its_until_completes_plainly(self):
        task = self.recurring(repeatFlag="RRULE:FREQ=DAILY;INTERVAL=1;UNTIL=20260902T235959Z")
        self.use_task(task)

        completed = self.cli["set_task_status"](task["id"], self.cli["STATUS_DONE"])

        self.assertEqual(completed["status"], self.cli["STATUS_DONE"])
        self.assertEqual(self.dispatched[0]["add"], [])

    def test_unsupported_rules_are_refused_before_dispatch(self):
        for flag in ("ERULE:NAME=EBBINGHAUS", "RRULE:FREQ=HOURLY", "RRULE:FREQ=DAILY;BYSETPOS=1"):
            with self.subTest(flag=flag):
                self.dispatched.clear()
                self.use_task(self.recurring(repeatFlag=flag))

                with self.assertRaisesRegex(self.cli["TickTickError"], "cannot be rolled forward"):
                    self.cli["set_task_status"]("task-1", self.cli["STATUS_DONE"])

                self.assertEqual(self.dispatched, [])

    def test_a_series_with_no_due_date_is_refused(self):
        task = self.task(repeatFlag="RRULE:FREQ=DAILY")
        self.use_task(task)

        with self.assertRaisesRegex(self.cli["TickTickError"], "no due date"):
            self.cli["set_task_status"](task["id"], self.cli["STATUS_DONE"])

        self.assertEqual(self.dispatched, [])

    def test_replayed_recurring_completion_advances_the_series(self):
        task = self.recurring()
        self.use_task(task)

        self.cli["replay"](
            {"kind": "complete", "payload": {"taskId": task["id"]}},
            {"token": "<REDACTED>"},
        )

        self.assertEqual(len(self.dispatched), 1)
        self.assertEqual(len(self.dispatched[0]["add"]), 1)
        self.assertEqual(self.dispatched[0]["update"][0]["status"], self.cli["STATUS_TODO"])

    def test_offline_recurring_completion_is_queued(self):
        task = self.recurring()
        self.use_task(task)
        self.globals["with_session"] = lambda _callback: (_ for _ in ()).throw(
            self.cli["TickTickError"]("offline", transient=True)
        )

        self.cli["set_task_status"](task["id"], self.cli["STATUS_DONE"])

        self.assertEqual(len(self.queued), 1)
        self.assertEqual(self.queued[0][0], "complete")

    def test_offline_completion_of_an_unsupported_rule_is_not_queued(self):
        task = self.recurring(repeatFlag="ERULE:NAME=EBBINGHAUS")
        self.use_task(task)
        self.globals["with_session"] = lambda _callback: (_ for _ in ()).throw(
            self.cli["TickTickError"]("offline", transient=True)
        )

        with self.assertRaisesRegex(self.cli["TickTickError"], "cannot be rolled forward"):
            self.cli["set_task_status"](task["id"], self.cli["STATUS_DONE"])

        self.assertEqual(self.queued, [])

    def test_plain_completion_is_unchanged(self):
        task = self.task()
        self.use_task(task)

        completed = self.cli["set_task_status"](task["id"], self.cli["STATUS_DONE"])

        self.assertEqual(completed["status"], self.cli["STATUS_DONE"])
        self.assertEqual(len(self.dispatched), 1)
        self.assertEqual(self.dispatched[0]["update"][0]["id"], task["id"])

    def test_recurring_task_can_still_be_reopened(self):
        task = self.task(status=self.cli["STATUS_DONE"], repeatFlag="RRULE:FREQ=DAILY")
        self.use_task(task)

        reopened = self.cli["set_task_status"](task["id"], self.cli["STATUS_TODO"])

        self.assertEqual(reopened["status"], self.cli["STATUS_TODO"])
        self.assertEqual(len(self.dispatched), 1)


class RecurrenceRuleTests(unittest.TestCase):
    """The date arithmetic on its own, where a wrong answer is cheapest to see."""

    @classmethod
    def setUpClass(cls):
        cls.cli = load_cli()

    def next_date(self, flag, dtstart, after):
        rule = self.cli["parse_repeat_rule"](flag)
        return self.cli["next_occurrence_date"](
            rule, date.fromisoformat(dtstart), date.fromisoformat(after)
        )

    def test_interval_is_anchored_to_the_series_start(self):
        # Every third day from the 1st: the 4th, never the 3rd.
        self.assertEqual(
            self.next_date("RRULE:FREQ=DAILY;INTERVAL=3", "2026-09-01", "2026-09-01"),
            date(2026, 9, 4),
        )

    def test_weekly_wraps_to_the_next_interval_week(self):
        self.assertEqual(
            self.next_date(
                "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,FR", "2026-09-07", "2026-09-11"
            ),
            date(2026, 9, 21),
        )

    def test_monthly_ordinal_weekday(self):
        # Third Monday of each month: 2026-09-21, then 2026-10-19.
        self.assertEqual(
            self.next_date("RRULE:FREQ=MONTHLY;INTERVAL=1;BYDAY=3MO", "2026-09-21", "2026-09-21"),
            date(2026, 10, 19),
        )

    def test_monthly_last_weekday_counts_back_from_the_end(self):
        self.assertEqual(
            self.next_date("RRULE:FREQ=MONTHLY;INTERVAL=1;BYDAY=-1FR", "2026-09-25", "2026-09-25"),
            date(2026, 10, 30),
        )

    def test_negative_monthday_is_the_last_day(self):
        self.assertEqual(
            self.next_date("RRULE:FREQ=MONTHLY;BYMONTHDAY=-1", "2026-09-30", "2026-09-30"),
            date(2026, 10, 31),
        )

    def test_monthly_skips_months_without_that_day(self):
        # The 31st does not exist in April, June, September or November.
        self.assertEqual(
            self.next_date("RRULE:FREQ=MONTHLY;INTERVAL=1", "2026-08-31", "2026-08-31"),
            date(2026, 10, 31),
        )

    def test_yearly_leap_day_lands_on_the_next_leap_year(self):
        self.assertEqual(
            self.next_date("RRULE:FREQ=YEARLY;INTERVAL=1", "2024-02-29", "2024-02-29"),
            date(2028, 2, 29),
        )

    def test_a_due_date_left_in_the_past_advances_one_step_only(self):
        self.assertEqual(
            self.next_date("RRULE:FREQ=DAILY;INTERVAL=1", "2026-01-01", "2026-01-05"),
            date(2026, 1, 6),
        )


class RecurrenceTimezoneTests(unittest.TestCase):
    """Whole-day shifts happen in the task's zone, not in UTC."""

    @classmethod
    def setUpClass(cls):
        cls.cli = load_cli()

    def test_wall_clock_time_survives_a_dst_boundary(self):
        # 9am New York on the Friday before US clocks go back, repeating weekly.
        task = {
            "id": "task-1",
            "repeatFlag": "RRULE:FREQ=WEEKLY;INTERVAL=1",
            "timeZone": "America/New_York",
            "startDate": "2026-10-30T13:00:00.000+0000",
            "dueDate": "2026-10-30T13:00:00.000+0000",
        }

        plan = self.cli["plan_recurring_completion"](task, "2026-10-30T14:00:00.000+0000")

        # Still 9am locally a week later, which is one hour later in UTC.
        self.assertEqual(plan["series"]["dueDate"], "2026-11-06T14:00:00.000+0000")

    def test_all_day_tasks_keep_their_midnight_marker(self):
        task = {
            "id": "task-1",
            "repeatFlag": "RRULE:FREQ=DAILY;INTERVAL=1",
            "isAllDay": True,
            "timeZone": "America/New_York",
            "startDate": "2026-10-30T00:00:00.000+0000",
            "dueDate": "2026-10-30T00:00:00.000+0000",
        }

        plan = self.cli["plan_recurring_completion"](task, "2026-10-30T14:00:00.000+0000")

        self.assertEqual(plan["series"]["dueDate"], "2026-10-31T00:00:00.000+0000")


class MaterialisedOccurrenceTests(unittest.TestCase):
    """A dated instance of a series is finished, not rolled forward.

    TickTick materialises future occurrences as tasks of their own: they link
    back with `repeatTaskId`, or carry `repeatFirstDate`, and hold no rule.
    Completing one is an ordinary write. Treating every recurrence marker as a
    live series refuses these, which breaks completions that work today.
    """

    def setUp(self):
        self.cli = load_cli()
        self.globals = self.cli["set_task_status"].__globals__
        self.dispatched = []

        def fake_batch_task(_session, add=None, update=None, delete=None):
            self.dispatched.append({"add": add or [], "update": update or [], "delete": delete or []})
            return {}

        def fake_with_session(callback):
            session = {"token": "<REDACTED>"}
            return callback(session), session

        self.globals["batch_task"] = fake_batch_task
        self.globals["with_session"] = fake_with_session
        self.globals["now_api_time"] = lambda: "2026-09-17T10:00:00.000+0000"

    def use_task(self, task):
        self.globals["cached_task"] = lambda _task_id: task
        self.globals["find_task"] = lambda _task_id, _session: task

    def test_series_head_is_the_task_carrying_the_rule(self):
        head = self.cli["is_series_head"]
        self.assertTrue(head({"repeatFlag": "RRULE:FREQ=WEEKLY"}))
        # An occurrence links back to its series and is not one itself.
        self.assertFalse(head({"repeatTaskId": "series-1"}))
        self.assertFalse(head({"repeatTaskId": "series-1", "repeatFlag": "RRULE:FREQ=WEEKLY"}))
        # Markers without a rule leave nothing to advance.
        self.assertFalse(head({"repeatFirstDate": "2026-09-02T08:00:00.000+0000"}))
        self.assertFalse(head({"repeatFrom": "2", "repeatFlag": ""}))
        self.assertFalse(head({"id": "plain"}))

    def occurrence(self, **fields):
        return {
            "id": "occurrence-1",
            "projectId": "project-1",
            "status": self.cli["STATUS_TODO"],
            "dueDate": "2026-09-21T09:00:00.000+0000",
            "timeZone": "Europe/Paris",
            **fields,
        }

    def assert_plain_completion(self, task):
        self.use_task(task)
        result = self.cli["set_task_status"](task["id"], self.cli["STATUS_DONE"])
        self.assertEqual(len(self.dispatched), 1)
        batch = self.dispatched[0]
        self.assertEqual(batch["add"], [], "an occurrence must not spawn a second task")
        self.assertEqual(len(batch["update"]), 1)
        self.assertEqual(batch["update"][0]["status"], self.cli["STATUS_DONE"])
        self.assertEqual(result["id"], task["id"])

    def test_an_occurrence_linked_to_its_series_completes_plainly(self):
        self.assert_plain_completion(self.occurrence(repeatTaskId="series-1"))

    def test_an_occurrence_with_only_a_first_date_completes_plainly(self):
        self.assert_plain_completion(
            self.occurrence(repeatFirstDate="2026-08-31T09:00:00.000+0000")
        )


class RepeatFromCompletionTests(unittest.TestCase):
    """repeatFrom="2" alongside a day filter, which real accounts are full of."""

    @classmethod
    def setUpClass(cls):
        cls.cli = load_cli()

    def plan(self, completed_time, **fields):
        task = {
            "id": "task-1",
            "repeatFrom": "2",
            "timeZone": "Europe/Paris",
            **fields,
        }
        return self.cli["plan_recurring_completion"](task, completed_time)

    def test_a_weekday_rule_lands_on_its_own_day(self):
        # Sunday noon in Paris, weekly on Sundays, finished on the day.
        plan = self.plan(
            "2026-09-20T11:00:00.000+0000",
            repeatFlag="RRULE:FREQ=WEEKLY;BYDAY=SU",
            dueDate="2026-09-20T10:00:00.000+0000",
        )
        self.assertEqual(plan["series"]["dueDate"], "2026-09-27T10:00:00.000+0000")

    def test_finishing_late_still_lands_on_the_next_allowed_day(self):
        # Ticked on the Tuesday: the next Sunday, not Tuesday plus a week.
        plan = self.plan(
            "2026-09-22T18:00:00.000+0000",
            repeatFlag="RRULE:FREQ=WEEKLY;BYDAY=SU",
            dueDate="2026-09-20T10:00:00.000+0000",
        )
        self.assertEqual(plan["series"]["dueDate"], "2026-09-27T10:00:00.000+0000")

    def test_a_dated_yearly_rule_keeps_its_month_and_day(self):
        plan = self.plan(
            "2026-09-26T08:00:00.000+0000",
            repeatFlag="RRULE:FREQ=YEARLY;BYMONTH=9;BYMONTHDAY=26",
            isAllDay=True,
            dueDate="2026-09-25T22:00:00.000+0000",
        )
        # Midnight Paris on the 26th, a year on.
        self.assertEqual(plan["series"]["dueDate"], "2027-09-25T22:00:00.000+0000")

    def test_a_positional_monthly_rule_keeps_its_position(self):
        # Third Friday of January 2027 -> third Friday of February.
        plan = self.plan(
            "2027-01-15T12:00:00.000+0000",
            repeatFlag="RRULE:FREQ=MONTHLY;BYDAY=3FR",
            dueDate="2027-01-15T09:00:00.000+0000",
        )
        self.assertEqual(plan["series"]["dueDate"], "2027-02-19T09:00:00.000+0000")

    def test_a_series_dated_ahead_is_not_dragged_back_to_today(self):
        # An imported birthday: finishing it early must not move it to
        # a year from this afternoon.
        plan = self.plan(
            "2026-09-17T10:00:00.000+0000",
            repeatFlag="RRULE:FREQ=YEARLY",
            isAllDay=True,
            dueDate="2041-03-10T23:00:00.000+0000",
        )
        self.assertEqual(plan["series"]["dueDate"], "2042-03-10T23:00:00.000+0000")

    def test_an_overdue_bare_rule_still_counts_from_the_completion(self):
        # No day filter and already past: "a year after I did it" is the
        # whole point of repeat-from-completion, so this one does drift.
        plan = self.plan(
            "2026-09-17T10:00:00.000+0000",
            repeatFlag="RRULE:FREQ=YEARLY",
            dueDate="2025-03-28T09:00:00.000+0000",
        )
        self.assertEqual(plan["series"]["dueDate"][:10], "2027-09-17")

    def test_a_weekday_rule_keeps_wall_clock_time_across_a_dst_boundary(self):
        # Noon Paris on 18 October; clocks go back on the 25th, so the same
        # noon is an hour earlier in UTC.
        plan = self.plan(
            "2026-10-18T11:00:00.000+0000",
            repeatFlag="RRULE:FREQ=WEEKLY;BYDAY=SU",
            dueDate="2026-10-18T10:00:00.000+0000",
        )
        self.assertEqual(plan["series"]["dueDate"], "2026-10-25T11:00:00.000+0000")

    def test_an_until_that_has_passed_ends_the_series(self):
        plan = self.plan(
            "2026-09-20T11:00:00.000+0000",
            repeatFlag="RRULE:FREQ=WEEKLY;BYDAY=SU;UNTIL=20260922T000000Z",
            dueDate="2026-09-20T10:00:00.000+0000",
        )
        self.assertIsNone(plan)


if __name__ == "__main__":
    unittest.main()
