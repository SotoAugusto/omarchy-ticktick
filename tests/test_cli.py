#!/usr/bin/env python3
"""Regression tests for state-changing CLI operations."""

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

    def test_online_recurring_completion_is_refused_before_dispatch(self):
        task = self.task(repeatFlag="RRULE:FREQ=DAILY")
        self.use_task(task)

        with self.assertRaisesRegex(self.cli["TickTickError"], "Recurring tasks cannot"):
            self.cli["set_task_status"](task["id"], self.cli["STATUS_DONE"])

        self.assertEqual(self.dispatched, [])

    def test_replayed_recurring_completion_is_refused_before_dispatch(self):
        task = self.task(repeatFrom="2")
        self.use_task(task)

        with self.assertRaisesRegex(self.cli["TickTickError"], "Recurring tasks cannot"):
            self.cli["replay"](
                {"kind": "complete", "payload": {"taskId": task["id"]}},
                {"token": "<REDACTED>"},
            )

        self.assertEqual(self.dispatched, [])

    def test_offline_recurring_completion_is_refused_before_queueing(self):
        task = self.task(repeatFlag="RRULE:FREQ=DAILY")
        self.use_task(task)
        self.globals["with_session"] = lambda _callback: (_ for _ in ()).throw(
            self.cli["TickTickError"]("offline", transient=True)
        )

        with self.assertRaisesRegex(self.cli["TickTickError"], "Recurring tasks cannot"):
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


if __name__ == "__main__":
    unittest.main()
