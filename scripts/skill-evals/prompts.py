import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SKILLS = Path('Sources/SillogCore/Chat/Skills')


def render(context, baseline):
    values = context['vars']
    path = SKILLS / (values['skill'] + '.md')
    instruction = subprocess.check_output(['git', 'show', os.environ['SILLOG_SKILL_BASE_REF'] + ':' + str(path)], cwd=ROOT, text=True) if baseline else (ROOT / path).read_text()
    return json.dumps({
        'system': 'You are Sillog. Answer the user in Korean. The user selected the following skill. In this evaluation, only the material in the request is available; no external tools are available.\n\n' + instruction,
        'user': values['request'],
    }, ensure_ascii=False)


def before(context):
    return render(context, True)


def after(context):
    return render(context, False)
