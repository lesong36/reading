import hashlib
import json
import unittest

from langchain_core.messages import AIMessage
from math_skills import SkillError, SnapshotBackend, complete_selection, json_repair_guidance, select_skills, selection_schema, snapshots_for
from test_math_skills import MESSAGES, ScriptModel, answer, skills, truth_answer
from test_math_tool_strategy import read, truth_decision, decision


def declared_roles(row, roles):
    row["selection_role_policy"] = json.dumps({
        "method_id": row["id"], "version_id": row["version_id"],
        "instructions_sha256": hashlib.sha256(row["instructions"].encode()).hexdigest(), "roles": roles})
    return row


class SelectionRoleTests(unittest.TestCase):
    def setUp(self):
        rows = skills(3)
        for row, roles in zip(rows, (["solution"], ["visual"], ["routing"])):
            declared_roles(row, roles)
        self.snapshots = snapshots_for(rows)

    def test_correct_roles_and_readable_router(self):
        value = json.loads(answer("id-0", ["id-1"]))
        self.assertEqual(selection_schema(self.snapshots).model_validate(value).model_dump(), value)
        backend = SnapshotBackend(self.snapshots)
        identities = json.loads(backend.identities)
        self.assertEqual(identities[2]["selection_roles"], ["routing"])
        router = next(path for path, identifier in backend.ids.items() if identifier == "id-2")
        self.assertIn(self.snapshots[2]["instructions"], backend.load_for_model(router))

    def test_wrong_roles_rejected_at_both_output_boundaries(self):
        for identifier, visuals in (("id-1", []), (None, ["id-0"]), ("id-2", []), (None, ["id-2"])):
            value = json.loads(answer(identifier, visuals))
            for validate in (lambda: selection_schema(self.snapshots).model_validate(value),
                             lambda: complete_selection(AIMessage(content=json.dumps(value)), self.snapshots)):
                with self.assertRaises(SkillError) as raised:
                    validate()
                self.assertTrue(raised.exception.issue.endswith(":role"))
                self.assertTrue(json_repair_guidance(raised.exception.issue))

    def test_custom_and_legacy_methods_do_not_inherit_a_role_from_names(self):
        rows = skills(2)
        rows[0].update(title="进销存图", selection_roles=["visual"])
        custom = snapshots_for(rows)
        value = json.loads(answer("id-0", ["id-1"]))
        self.assertEqual(selection_schema(custom).model_validate(value).model_dump(), value)
        legacy = AIMessage(content=answer("id-1", ["id-0"]))
        self.assertEqual(complete_selection(legacy, self.snapshots, require_applicability=False)["method_id"], "id-1")

    def test_declaration_is_exact_snapshot_bound_and_strict(self):
        row = declared_roles(skills(1)[0], ["solution"])
        original = row["selection_role_policy"]
        mutations = [dict(row, instructions=row["instructions"] + " "), dict(row, version_id="edited")]
        for roles in ([], ["bogus"], ["visual", "visual"], ["routing", "solution"], [True]):
            mutations.append(declared_roles(dict(row), roles))
        duplicate = original[:-1] + ', "roles":["visual"]}'
        mutations.append(dict(row, selection_role_policy=duplicate))
        for mutation in mutations:
            with self.assertRaises(SkillError) as raised:
                snapshots_for([mutation])
            self.assertEqual(raised.exception.code, "skillsInvalid")


class SelectionRoleGraphTests(unittest.IsolatedAsyncioTestCase):
    async def test_swapped_roles_get_only_existing_single_repair(self):
        rows = skills(2)
        declared_roles(rows[0], ["solution"]); declared_roles(rows[1], ["visual"])
        snapshots = snapshots_for(rows)
        paths = list(SnapshotBackend(snapshots).files)
        model = ScriptModel()
        model._responses = [AIMessage(content="", tool_calls=[read(path, i).tool_calls[0] for i, path in enumerate(paths)]),
                            decision(json.loads(answer("id-1", ["id-0"]))),
                            decision(json.loads(answer("id-0", ["id-1"]))),
                            truth_decision(json.loads(truth_answer("id-0", ["id-1"])))]
        raw, details = await select_skills(model, MESSAGES, snapshots)
        self.assertEqual(json.loads(raw)["method_id"], "id-0")
        self.assertEqual(details["protocol_repairs"], ["selection.method_id:role"])
        self.assertEqual(details["model_calls"], 4)
        self.assertEqual(details["loaded_skill_ids"], ["id-0", "id-1"])

    async def test_repeated_wrong_role_cannot_consume_more_repairs(self):
        rows = skills(1); declared_roles(rows[0], ["visual"])
        snapshots = snapshots_for(rows); path = next(iter(SnapshotBackend(snapshots).files))
        model = ScriptModel(); model._responses = [read(path), decision(), decision(), decision()]
        with self.assertRaises(SkillError) as raised:
            await select_skills(model, MESSAGES, snapshots)
        self.assertEqual(raised.exception.issue, "selection.method_id:role")
        self.assertEqual(len(model._calls), 3)
