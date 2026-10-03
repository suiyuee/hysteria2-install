"""Reproducibly bundle the installer and assets into a standalone shell script."""
import argparse
import ast
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def bundle():
    source = (ROOT / 'src/installer.py').read_text()
    for name, asset in [('SITE', 'index.html'), ('SERVICE', 'hysteria-server.service')]:
        line = f"{name} = (Path(__file__).resolve().parents[1] / 'assets/{asset}').read_text()"
        assert source.count(line) == 1
        source = source.replace(line, f'{name} = {(ROOT / "assets" / asset).read_text()!r}')
    ast.parse(source)
    return ((ROOT / 'scripts/launcher.sh').read_text()
            + 'python3 - "$@" <<\'PYTHON\'\n' + source.rstrip() + '\nPYTHON\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    text = bundle()
    path = ROOT / 'dist/hysteria.sh'
    if args.check:
        if not path.exists() or path.read_text() != text:
            raise SystemExit('dist/hysteria.sh 未同步，请运行 python3 scripts/build.py')
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)


if __name__ == '__main__':
    main()
