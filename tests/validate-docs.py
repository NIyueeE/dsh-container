#!/usr/bin/env python3
"""文档静态校验: 相对链接可解析 + README/README.zh 结构对齐。

从 CI 的内联步骤抽出, 使同一套判据可以在轻门里本地运行
(`python3 tests/validate-docs.py`, 或经 `just lint`), 不必推 CI 才知道文档坏了。

用法:
    tests/validate-docs.py [links|parity|all]      # 默认 all

判据(与原内联步骤逐条一致):
  links   仓库根 *.md 与 docs/*.md 里的相对链接必须能在仓库内解析
          (跳过 http/https/mailto 与纯锚点)。
  parity  README.md 与 README.zh.md 的标题数、链接数、代码围栏数必须相等 ——
          README.md 是唯一真源, 中文版只译散文(见 AGENTS.md)。

退出码: 0 全部通过; 1 有违规(逐条打印到 stdout/stderr)。
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def check_links() -> list[str]:
    """返回相对链接无法解析的 "文件: 链接" 列表。"""
    bad: list[str] = []
    for md in sorted(list(ROOT.glob("*.md")) + list(ROOT.glob("docs/*.md"))):
        for link in re.findall(r"\]\(([^)#]+)", md.read_text(encoding="utf-8")):
            if link.startswith(("http", "mailto:", "#")):
                continue
            if not (md.parent / link).exists():
                bad.append(f"{md.relative_to(ROOT)}: {link}")
    return bad


def check_parity() -> list[str]:
    """返回 README 中英两版结构不一致的描述列表。"""
    en = (ROOT / "README.md").read_text(encoding="utf-8")
    zh = (ROOT / "README.zh.md").read_text(encoding="utf-8")

    def headings(text: str) -> list[str]:
        return re.findall(r"^#{1,6} .*$", text, re.M)

    def links(text: str) -> int:
        return len(re.findall(r"\[[^\]]*\]\([^)]*\)", text))

    problems: list[str] = []
    if len(headings(en)) != len(headings(zh)):
        problems.append(f"heading count mismatch: en={len(headings(en))} zh={len(headings(zh))}")
    if links(en) != links(zh):
        problems.append(f"link count mismatch: en={links(en)} zh={links(zh)}")
    if en.count("```") != zh.count("```"):
        problems.append(f"code fence count mismatch: en={en.count('```')} zh={zh.count('```')}")
    return problems


def main(argv: list[str]) -> int:
    mode = argv[1] if len(argv) > 1 else "all"
    if mode not in ("links", "parity", "all"):
        print(f"usage: {argv[0]} [links|parity|all]", file=sys.stderr)
        return 64

    failed = False
    if mode in ("links", "all"):
        bad = check_links()
        if bad:
            failed = True
            print("\n".join(bad))
            print(f"{len(bad)} broken relative doc link(s)", file=sys.stderr)
        else:
            print("all relative doc links resolve")
    if mode in ("parity", "all"):
        problems = check_parity()
        if problems:
            failed = True
            print("\n".join(problems), file=sys.stderr)
        else:
            print("README parity OK")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
