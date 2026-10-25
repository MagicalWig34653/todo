#!/usr/bin/env python3
"""Move the handoff into the main repository and initialize both repositories."""

import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).digest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--main', type=Path, default=Path('/Users/linolaske/Documents/Code Projekte/PhpstormProjects/todo'))
    parser.add_argument('--apple', type=Path, default=Path('/Users/linolaske/Documents/Code Projekte/Xcode/todo'))
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    target = args.main.expanduser().resolve()
    apple = args.apple.expanduser().resolve()
    paths = [source, target, apple]
    for i, left in enumerate(paths):
        for right in paths[i + 1:]:
            if left == right or left in right.parents or right in left.parents:
                raise SystemExit('Source and targets must be separate, non-nested directories.')
    for directory in [target, apple]:
        if directory.exists() and (not directory.is_dir() or any(directory.iterdir())):
            raise SystemExit(f'Target is not empty; nothing changed: {directory}')
    if not shutil.which('git'):
        raise SystemExit('Git is required; nothing changed.')
    files = sorted(p for p in source.rglob('*') if p.is_file())
    if any(p.is_symlink() for p in source.rglob('*')):
        raise SystemExit('Unexpected symlink in source; nothing changed.')
    hashes = {p: digest(p) for p in files}
    for directory in [target, apple]:
        directory.mkdir(parents=True, exist_ok=True)
    # Keep the source intact until copying, customization and Git setup succeed.
    for path in files:
        destination = target / path.relative_to(source)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
        if digest(destination) != hashes[path]:
            raise RuntimeError(f'Copy verification failed: {path}')

    def write(root, name, content):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding='utf-8')

    ignore = '.DS_Store\n.workspace.local.json\n.env\n.env.*\n!.env.example\n.build/\nnode_modules/\n.svelte-kit/\nDerivedData/\nxcuserdata/\n'
    write(target, '.gitignore', ignore)
    write(apple, '.gitignore', ignore)
    import json
    workspace = json.dumps({'mainRepo': str(target), 'appleRepo': str(apple)}, indent=2) + '\n'
    for root in [target, apple]:
        write(root, '.workspace.local.json', workspace)
    rules = (target / 'templates/AGENTS.md').read_text()
    rules = rules.replace(rules.split('\n')[2], 'Dies ist das Hauptrepository für Backend, PWA und das globale Projektgedächtnis. Alle globalen Dokumente liegen unter docs/. Das Apple-Repository ist über .workspace.local.json auffindbar.')
    write(target, 'AGENTS.md', rules)
    apple_rules = rules.replace('Dies ist das Hauptrepository für Backend, PWA und das globale Projektgedächtnis. Alle globalen Dokumente liegen unter docs/. Das Apple-Repository ist über .workspace.local.json auffindbar.', 'Dies ist das Apple-Repository. Lies zuerst .workspace.local.json und dann AGENTS.md, docs/STATUS.md und docs/ARBEITSPLAN.md im dort genannten mainRepo. Globale Dokumentation liegt ausschließlich im Hauptrepository. Lokaler Stand: docs/STATUS.md.')
    write(apple, 'AGENTS.md', apple_rules)
    claude = (target / 'templates/CLAUDE.md').read_text()
    claude = claude.replace(claude.split('\n')[2], 'Hauptrepository: globale Dokumentation unter docs/, aktueller Arbeitsplan unter docs/ARBEITSPLAN.md.')
    write(target, 'CLAUDE.md', claude)
    write(apple, 'CLAUDE.md', '# Claude Code – Apple-Apps\n\nLies AGENTS.md und .workspace.local.json. Beginne im mainRepo mit docs/STATUS.md und docs/ARBEITSPLAN.md, danach hier mit docs/STATUS.md. Sessions sind wegwerfbar; halte beide betroffenen Dokumentationsstände während der Arbeit aktuell.\n')
    write(apple, 'README.md', '# Todo – Apple-Apps\n\nSwiftUI für iPhone, iPad, Mac und Apple Watch, einschließlich Mac-Agenten-Runner.\n\nDas Backend-/PWA-Repository ist das Hauptarbeitsrepo und die Source of Truth. Sein lokaler Pfad steht in .workspace.local.json unter mainRepo. Bei einem frischen Checkout diese ignorierte Datei mit mainRepo und appleRepo als absoluten Pfaden anlegen. Dort README.md, AGENTS.md und docs/STATUS.md lesen.\n\nHier wurden bislang nur Repository und Agenteneinstiege eingerichtet. Kein Xcode-Projekt und keine Anwendung implementiert.\n')
    write(apple, 'docs/STATUS.md', '# Apple – Status\n\nRepository und Agenteneinstiege eingerichtet. Noch keine App-Quellen, Xcode-Projekte oder Builds vorhanden. Nächster Schritt: mit dem Arbeitsplan im Hauptrepository abgleichen und Apple-Grundgerüst aufsetzen. Globale Auswirkungen stets auch dort dokumentieren.\n')
    readme = (target / 'README.md').read_text()
    start = readme.index('Diese Unterlagen')
    end = readme.index('## Dokumente')
    readme = readme[:start] + 'Dies ist das Hauptarbeitsrepo für Backend und PWA sowie das kanonische Projektgedächtnis. Das separate Apple-Repo enthält SwiftUI-Apps und Mac-Runner. Beide Git-Repositories sind initialisiert; Anwendungscode ist noch nicht implementiert.\n\n## Einstieg\n\nClaude Code hier öffnen und STARTPROMPT.md lesen. AGENTS.md enthält die verbindlichen Arbeitsregeln. Den lokalen Apple-Pfad findest du in der ignorierten .workspace.local.json. Diese Datei bei einem neuen Checkout passend anlegen.\n\n' + readme[end:]
    write(target, 'README.md', readme)
    prompt = (target / 'STARTPROMPT.md').read_text()
    start = prompt.index('Das Übergabepaket liegt')
    end = prompt.index('## Technischer Ausgangspunkt')
    prompt = prompt[:start] + 'Arbeite aus diesem Backend-/PWA-Hauptrepository. Lies AGENTS.md, README.md, docs/STATUS.md, docs/ARBEITSPLAN.md und die übrigen Konzeptdokumente. Beide Repositories und ihre Agenteneinstiege sind bereits eingerichtet. Die lokalen Pfade stehen in .workspace.local.json. Keine neuen Repositories oder unabhängigen Konzeptkopien anlegen.\n\nSessions sind wegwerfbar. Das Repository ist die Source of Truth. Aktualisiere Entscheidungen, Status, Arbeitsplan und Prüfnachweise nach jedem abgeschlossenen Teilschritt und vor Kontextwechseln.\n\n' + prompt[end:]
    prompt = prompt.replace('2. Beide Repositories samt Agenteneinstiegen und Dokumentationsstruktur anlegen.', '2. Vorhandene Repository-Struktur und Agenteneinstiege prüfen; Arbeitsplan aktualisieren.')
    write(target, 'STARTPROMPT.md', prompt)
    write(target, 'docs/STATUS.md', '# Status\n\nBeide Git-Repositories eingerichtet. Backend/PWA ist das Hauptarbeitsrepo; Apple verweist auf dieses Projektgedächtnis. Produkt-, Architektur-, Rechte-, MCP- und Umsetzungsdokumente sind übernommen. Sessions sind wegwerfbar; Dokumentation bleibt während der Arbeit aktuell.\n\nNoch keine Anwendungsquellen, installierten Abhängigkeiten, Builds, Geräteprüfungen oder Swarm-Nachweise.\n\nDie Einrichtung hat die übertragenen Dateien per SHA-256 geprüft und beide Git-Wurzeln kontrolliert. Nächster Schritt: docs/ARBEITSPLAN.md und STARTPROMPT.md lesen; Etappe 0 umsetzen.\n')
    write(target, 'docs/ARBEITSPLAN.md', '# Arbeitsplan\n\n## Stand\n\nRepository-Einrichtung und Dokumentationsübernahme abgeschlossen. Kein Implementierungsauftrag aktiv.\n\n## Nächster Abschnitt\n\nEtappe 0 aus UMSETZUNGSPLAN.md: Referenzen und Stack prüfen, ADRs festhalten, Backend/PWA mit MariaDB und Apple-Grundgerüst aufsetzen, Linux-Build und Runner-Machbarkeit prüfen. Danach erster persönlicher vertikaler Schnitt.\n\n## Checkpoints\n\nNach jedem abgeschlossenen Teilschritt STATUS.md und diesen Plan aktualisieren: tatsächliche Änderungen, Repositories/Branches, ausgeführte Checks, offene Probleme, laufende Prozesse und nächster Schritt. Keine Fortsetzung auf Basis alter Chats voraussetzen.\n')
    for directory in [target, apple]:
        subprocess.run(['git', 'init', '-b', 'main', str(directory)], check=True)
        actual = subprocess.check_output(['git', '-C', str(directory), 'rev-parse', '--show-toplevel'], text=True).strip()
        if Path(actual).resolve() != directory:
            raise RuntimeError(f'Unexpected Git root: {actual}')
    for path in files:
        if digest(path) != hashes[path]:
            raise RuntimeError('Source changed during setup; preserved all source files.')
    for path in files:
        path.unlink()
    for directory in sorted((p for p in source.rglob('*') if p.is_dir()), key=lambda p: len(p.parts), reverse=True):
        if not any(directory.iterdir()):
            directory.rmdir()
    print(f'Main repository: {target}\nApple repository: {apple}\nSource files moved. No commits, remotes or pushes created.')


if __name__ == '__main__':
    main()
