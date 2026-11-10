"""앱 패키지의 복사본에 평가 실행기만 추가한다. 설치 앱은 교체하지 않는다."""
from pathlib import Path
import os
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
work = root / 'build/skill-evals'
stage = work / 'source'
stage.mkdir(parents=True, exist_ok=True)
for directory in ['Sources', 'Tests']:
    shutil.copytree(root / directory, stage / directory, dirs_exist_ok=True)
shutil.copy2(root / 'Package.resolved', stage / 'Package.resolved')
manifest = (root / 'Package.swift').read_text()
manifest = manifest.replace('products: [', 'products: [.executable(name: "SkillEval", targets: ["SkillEval"]),', 1)
manifest = manifest.replace('targets: [\n', 'targets: [\n        .executableTarget(name: "SkillEval", dependencies: ["WorkGraphCore"], path: "SkillEval"),\n', 1)
(stage / 'Package.swift').write_text(manifest)
(stage / 'SkillEval').mkdir(exist_ok=True)
shutil.copy2(Path(__file__).with_name('runner.swift'), stage / 'SkillEval/runner.swift')
scratch = Path(os.environ.get('SILLOG_EVAL_SCRATCH', work / 'scratch')).resolve()
args = ['swift', 'build', '--package-path', str(stage), '--scratch-path', str(scratch), '-c', 'release', '--disable-sandbox']
subprocess.run(args + ['--product', 'SkillEval', '-j', '2'], check=True)
binary = Path(subprocess.check_output(args + ['--show-bin-path'], text=True).strip()) / 'SkillEval'
(work / 'binary-path.txt').write_text(str(binary))
print(binary)
