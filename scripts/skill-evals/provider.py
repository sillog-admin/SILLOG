"""Promptfoo adapter: uses SILLOG's existing ChatGPT authentication without exporting tokens."""
import json
import os
import subprocess


def call_api(prompt, options, context):
    try:
        payload = json.loads(prompt)
    except (ValueError, TypeError):
        payload = {'system': 'Evaluate the supplied response against the rubric. Return only the requested JSON.', 'user': prompt}
    if not isinstance(payload, dict) or 'system' not in payload or 'user' not in payload:
        payload = {'system': 'Evaluate the supplied response against the rubric. Return only the requested JSON.', 'user': prompt}
    run = subprocess.run([os.environ['SILLOG_EVAL_BINARY'], os.environ['SILLOG_EVAL_MODEL']],
                         input=json.dumps(payload, ensure_ascii=False), text=True, capture_output=True, timeout=180)
    if run.returncode:
        return {'error': 'SILLOG evaluation request failed; check authentication and model access.'}
    return json.loads(run.stdout)
