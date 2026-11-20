#!/usr/bin/env python3
"""draw.io로 내보낸 SVG의 아이콘 간 id 충돌을 제거한다.

draw.io는 SVG 아이콘을 셰이프로 붙여넣을 때 아이콘 내부의 id(`id="A"`, `id="a"` 등)를
그대로 둔다. 편집기에서는 아이콘마다 독립된 문서로 그려지므로 문제가 없지만,
SVG로 내보내면 모든 아이콘이 하나의 문서에 인라인되면서 같은 id가 중복된다.
이때 `<use xlink:href="#A">`나 `fill="url(#a)"`는 문서 순서상 가장 먼저 나온 정의로
해석되므로, 예를 들어 S3 아이콘이 EC2 아이콘으로 그려진다.

이 스크립트는 중첩된 `<svg>` 블록(=아이콘 하나)마다 내부 id에 고유 접두어를 붙이고
같은 블록 안의 참조만 함께 바꿔 충돌을 없앤다. 재내보내기할 때마다 다시 실행하면 된다.

사용법:
    python scripts/fix-svg-duplicate-ids.py docs/images/다이어그램.svg
"""

from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path


def split_root(svg: str) -> tuple[str, str]:
    """루트 <svg ...> 여는 태그와 나머지 본문을 분리한다.

    루트 태그의 content 속성에는 mxfile 원본이 escape되어 들어 있으므로
    따옴표 안의 '>'를 태그 종료로 오인하지 않도록 직접 훑는다.
    """
    start = svg.find("<svg")
    if start < 0:
        raise ValueError("루트 <svg> 태그를 찾지 못했다")
    quote = None
    i = start
    while i < len(svg):
        ch = svg[i]
        if quote:
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch == ">":
            break
        i += 1
    return svg[: i + 1], svg[i + 1 :]


def find_nested_svg_blocks(body: str) -> list[tuple[int, int]]:
    """본문에서 최상위 중첩 <svg> 블록의 (시작, 끝) 오프셋을 찾는다."""
    blocks: list[tuple[int, int]] = []
    pos = 0
    while True:
        start = body.find("<svg", pos)
        if start < 0:
            return blocks
        depth = 0
        i = start
        while i < len(body):
            if body.startswith("<svg", i):
                depth += 1
                i += 4
            elif body.startswith("</svg", i):
                depth -= 1
                i += 5
                if depth == 0:
                    end = body.find(">", i) + 1
                    blocks.append((start, end))
                    pos = end
                    break
            else:
                i += 1
        else:
            return blocks


def rewrite_style_selectors(chunk: str, old: str, new: str) -> str:
    """<style> 블록 안의 `#old` 선택자를 `#new`로 바꾼다.

    draw.io는 아이콘 CSS를 `#svg-image-xxxx .st0 { ... }`처럼 래퍼 id로 한정한다.
    id만 바꾸고 선택자를 두면 규칙이 매칭되지 않아 색이 사라진다(기본값 검정).
    """
    pattern = re.compile(r"#" + re.escape(old) + r"(?![\w\-])")

    def replace_block(match: re.Match[str]) -> str:
        return pattern.sub(f"#{new}", match.group(0))

    return re.sub(r"<style\b[^>]*>.*?</style>", replace_block, chunk, flags=re.S)


def scope_ids(svg: str) -> tuple[str, int, int]:
    head, body = split_root(svg)
    blocks = find_nested_svg_blocks(body)

    # 실제로 겹치는 id만 바꾼다. draw.io가 이미 고유하게 만든 래퍼 id까지 건드리면
    # 그 id에 걸린 CSS 선택자나 외부 참조가 끊어진다.
    counts: Counter[str] = Counter()
    for start, end in blocks:
        counts.update(set(re.findall(r'\bid="([^"]+)"', body[start:end])))
    duplicated = {name for name, count in counts.items() if count > 1}

    parts: list[str] = []
    last = 0
    renamed = 0
    for index, (start, end) in enumerate(blocks):
        parts.append(body[last:start])
        chunk = body[start:end]
        names = set(re.findall(r'\bid="([^"]+)"', chunk)) & duplicated
        # 긴 이름부터 바꿔야 짧은 이름이 긴 이름의 일부를 훼손하지 않는다.
        for old in sorted(names, key=len, reverse=True):
            new = f"ic{index}_{old}"
            chunk = chunk.replace(f'id="{old}"', f'id="{new}"')
            chunk = chunk.replace(f'href="#{old}"', f'href="#{new}"')
            chunk = chunk.replace(f"url(#{old})", f"url(#{new})")
            chunk = chunk.replace(f"url('#{old}')", f"url('#{new}')")
            chunk = rewrite_style_selectors(chunk, old, new)
            renamed += 1
        parts.append(chunk)
        last = end
    parts.append(body[last:])
    return head + "".join(parts), len(blocks), renamed


def verify(svg: str) -> None:
    _, body = split_root(svg)
    ids = Counter(re.findall(r'\bid="([^"]+)"', body))
    duplicated = {name: count for name, count in ids.items() if count > 1}
    if duplicated:
        raise SystemExit(f"중복 id가 남았다: {duplicated}")

    refs = set(re.findall(r'href="#([^"]+)"', body)) | set(
        re.findall(r"url\(#([^)]+)\)", body)
    )
    unresolved = sorted(ref for ref in refs if f'id="{ref}"' not in body)
    if unresolved:
        raise SystemExit(f"참조를 찾지 못한 id: {unresolved}")
    print(f"검증 통과: 중복 id 0개, 참조 {len(refs)}개 모두 해석됨")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 1
    path = Path(argv[1])
    original = path.read_text(encoding="utf-8")
    fixed, blocks, renamed = scope_ids(original)
    verify(fixed)
    if fixed == original:
        print(f"{path}: 바꿀 내용이 없다")
        return 0
    path.write_text(fixed, encoding="utf-8")
    print(f"{path}: 아이콘 {blocks}개, id {renamed}개에 접두어를 붙였다")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
