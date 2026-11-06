import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import question_engine as engine
from math_learning import LearningOutputError
from math_skills import SkillError


class LearningErrorEvents(unittest.IsolatedAsyncioTestCase):
    async def event(self, error):
        async def failing(*_):
            raise error
        events = []
        with patch.object(engine, 'stream_answer', failing):
            await engine.run_request({'id': 'isolated', 'task': 'math_skill_learning'}, events.append)
        self.assertEqual(len(events), 1)
        return events[0]

    async def test_safe_stage_diagnostics_survive_protocol(self):
        event = await self.event(LearningOutputError('pattern_key', 'coverage', 2))
        self.assertEqual(event, {'id': 'isolated', 'type': 'error', 'code': 'learningOutput',
                                'learning_stage': 'coverage', 'learning_issue': 'pattern_key', 'model_calls': 2})

    async def test_unknown_diagnostic_never_echoes_rejected_output(self):
        event = await self.event(LearningOutputError('untrusted-secret', 'untrusted-secret', 2))
        self.assertEqual(event, {'id': 'isolated', 'type': 'error', 'code': 'learningOutput'})
        event = await self.event(LearningOutputError('fields', 'draft', True))
        self.assertNotIn('model_calls', event)

    async def test_input_validation_is_separate_from_model_output(self):
        event = await self.event(SkillError('learningInvalid'))
        self.assertEqual(event, {'id': 'isolated', 'type': 'error', 'code': 'learningInvalid'})
