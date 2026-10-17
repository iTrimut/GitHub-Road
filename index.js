// GitHub-Road — skills-only DSH plugin bundle.
// Minimal cordis plugin: the real content is the Agent Skills under skills/,
// which this plugin copies into ~/.dsh/skills/ on boot (mirrors dsh-webroad).
// Every subdirectory of skills/ that contains a SKILL.md is installed, so the
// bundle can ship more than one skill (e.g. GitHub-Road and github-road-linux).
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { existsSync, mkdirSync, readdirSync, statSync, copyFileSync } from 'node:fs';

const HERE = dirname(fileURLToPath(import.meta.url));

function copyTree(src, dst) {
  mkdirSync(dst, { recursive: true });
  for (const entry of readdirSync(src)) {
    const from = join(src, entry);
    const to = join(dst, entry);
    if (statSync(from).isDirectory()) copyTree(from, to);
    else copyFileSync(from, to);
  }
}

export default {
  apply() {
    try {
      const dshHome = process.env.DSH_HOME || join(homedir(), '.dsh');
      const skillsRoot = join(HERE, 'skills');
      if (!existsSync(skillsRoot)) return;
      for (const name of readdirSync(skillsRoot)) {
        const source = join(skillsRoot, name);
        if (!existsSync(join(source, 'SKILL.md'))) continue;
        const target = join(dshHome, 'skills', name);
        if (existsSync(join(target, 'SKILL.md'))) continue; // never overwrite user edits
        copyTree(source, target);
      }
    } catch { /* best-effort, non-fatal */ }
  }
};
