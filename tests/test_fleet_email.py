# SPDX-License-Identifier: MIT
"""Exercise the actual workflow email renderer with an in-memory SMTP transport."""
import json
import os
from pathlib import Path
import tempfile
import textwrap
import unittest
from unittest.mock import patch

WORKFLOW = Path(__file__).resolve().parents[1] / '.github/workflows/update-managed-repositories.yml'
SOURCE = textwrap.dedent(WORKFLOW.read_text(encoding='utf-8').split("          python - <<'PY'\n", 1)[1].split('\n          PY', 1)[0])

class ReportTests(unittest.TestCase):
    def render(self, mode, names=True):
        captured = []
        class Transport:
            def __init__(self, *args, **kwargs): pass
            def ehlo(self): pass
            def starttls(self, **kwargs): pass
            def login(self, *args): pass
            def send_message(self, message): captured.append(message)
            def quit(self): pass
        with tempfile.TemporaryDirectory() as temporary:
            report = Path(temporary) / 'report.json'
            report.write_text(json.dumps([{'repository':'example/project', 'visibility':'Private', 'runner':'runner-one\nrunner-two', 'status':'Available', 'comment':'Update available.'}]), encoding='utf-8')
            environment = {'PRIVATE_REPORT_PATH':str(report), 'SMTP_HOST':'smtp.example.invalid', 'SMTP_PORT':'587', 'SMTP_USERNAME':'synthetic', 'SMTP_PASSWORD':'synthetic', 'MESSAGE_FROM_EMAIL':'sender@example.invalid', 'MESSAGE_TO_EMAIL':'recipient@example.invalid', 'MESSAGE_FROM_NAME':'Report Sender' if names else ' ', 'MESSAGE_TO_NAME':'Report Recipient' if names else '', 'ROLLOUT_MODE':mode, 'ROLLOUT_OUTCOME':'success', 'RELEASE_TAG':'v3.1.3', 'GITHUB_SERVER_URL':'https://github.com', 'GITHUB_REPOSITORY':'example/quality', 'GITHUB_RUN_ID':'123'}
            with patch.dict(os.environ, environment, clear=True), patch('smtplib.SMTP', Transport):
                exec(compile(SOURCE, str(WORKFLOW), 'exec'), {'__name__':'__main__'})
        self.assertEqual(len(captured), 1)
        return captured[0]

    def test_preview_is_not_a_deployment_claim(self):
        message = self.render('preview')
        self.assertEqual(message['Subject'], '[RQG] Fleet Preview SUCCESS: v3.1.3')
        for content in (message.get_body(preferencelist=('plain',)).get_content(), message.get_body(preferencelist=('html',)).get_content()):
            self.assertIn('no repository changes were applied', content)
            self.assertIn('this preview did not apply it', content)
        markup = message.get_body(preferencelist=('html',)).get_content()
        self.assertIn('runner-one<br>runner-two', markup)
        self.assertIn('example/project', markup)
        self.assertIn('border:1px solid #999', markup)
        self.assertIn('Report Sender', message['From'])
        self.assertIn('Report Recipient', message['To'])

    def test_apply_keeps_rollout_identity(self):
        message = self.render('apply', names=False)
        self.assertEqual(message['Subject'], '[RQG] Fleet Rollout SUCCESS: v3.1.3')
        self.assertIn('Applied rollout:', message.get_body(preferencelist=('plain',)).get_content())
        self.assertNotIn('no repository changes were applied', message.get_body(preferencelist=('html',)).get_content())
        self.assertIn('sender@example.invalid', message['From'])
        self.assertIn('recipient@example.invalid', message['To'])

    def test_missing_or_invalid_mode_cannot_send(self):
        for mode in ('', 'deploy', 'unexpected'):
            with self.subTest(mode=mode), self.assertRaisesRegex(RuntimeError, 'explicit preview or apply mode'):
                self.render(mode)

if __name__ == '__main__':
    unittest.main()
