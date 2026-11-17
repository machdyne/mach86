#!/usr/bin/env python3
"""Check relative links and #anchors in the repository's Markdown files.

Exits non-zero and lists every broken link. External (scheme://) links
are not fetched.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LINK = re.compile(r'(?<!\!)\[[^\]]*\]\(([^)\s]+)\)')
HEADING = re.compile(r'^#{1,6}\s+(.*?)\s*$')


def slug(text):
    """GitHub's heading-to-anchor rule, near enough for our headings."""
    text = re.sub(r'`', '', text).strip().lower()
    text = re.sub(r'[^\w\- ]', '', text)
    return text.replace(' ', '-')


def anchors(path):
    out, fenced = set(), False
    with open(path, encoding='utf-8') as f:
        for line in f:
            if line.startswith('```'):
                fenced = not fenced
            m = None if fenced else HEADING.match(line)
            if m:
                out.add(slug(m.group(1)))
    return out


def md_files():
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in ('.git', 'output')]
        for name in files:
            if name.endswith('.md'):
                yield os.path.join(base, name)


def main():
    bad = []
    for path in sorted(md_files()):
        fenced = False
        with open(path, encoding='utf-8') as f:
            for n, line in enumerate(f, 1):
                if line.startswith('```'):
                    fenced = not fenced
                if fenced:
                    continue
                for target in LINK.findall(line):
                    if re.match(r'[a-z][a-z0-9+.-]*:', target):
                        continue
                    file_part, _, frag = target.partition('#')
                    dest = (os.path.normpath(os.path.join(
                        os.path.dirname(path), file_part))
                        if file_part else path)
                    where = '%s:%d' % (os.path.relpath(path, ROOT), n)
                    if not os.path.exists(dest):
                        bad.append('%s: missing file %s' % (where, target))
                    elif frag and dest.endswith('.md') \
                            and frag not in anchors(dest):
                        bad.append('%s: missing anchor %s' % (where, target))
    for b in bad:
        print(b)
    print('checkdocs: %d broken link(s)' % len(bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
