"""Conservative cleanup of verbatim adjacent dictation restarts.

Apply only to an already successful model output; never to ASR history or an
error fallback. This returns a new string and does not mutate its input.

Scope: at least three identical comma-separated clauses with at least six
letters, including four CJK letters. Keep one copy and the final delimiter. Quotes, code-like
lines, colon-led blocks, quantities, list lines, questions and exclamations are left
alone. Two repetitions remain untouched: they may express emphasis.
The detector cannot prove intent; unmarked repeated emphasis is still ambiguous.
Time and auxiliary memory are O(n); no dependencies or model calls are needed.
"""
import re

# Lists and notation are not prose restarts. Skip their whole line instead of
# guessing whether an item, quantity, or literal token may be removed.
_UNSAFE_LINE = re.compile(r"[\"'“”‘’「」『』《》〈〉`{}\[\]<>＝=\\]|^\s*(?:[-*+•]|(?:[0-9０-９一二三四五六七八九十]+)[.、)）])")
_NUMERIC = re.compile(r"[0-9０-９零〇一二两三四五六七八九十百千万亿壹贰叁肆伍陆柒捌玖拾佰仟萬億]")
_CLAUSE_END = re.compile(r"[,，。.;；!?！？]")
_CJK = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]")


def _eligible(body):
    # No whitespace normalization inside a clause: only truly identical wording
    # qualifies. Quantities (including Chinese numerals) remain untouched.
    return (len(_CJK.findall(body)) >= 4 and sum(char.isalpha() for char in body) >= 6
            and not _NUMERIC.search(body))


def _clean_line(line):
    if _UNSAFE_LINE.search(line):
        return line
    # splitlines(keepends=True) passes the line ending through. Preserve it
    # separately so a final clause without punctuation cannot consume a break.
    content = line.rstrip()
    trailing = line[len(content):]
    line = content
    pieces = []
    start = 0
    for match in _CLAUSE_END.finditer(line):
        pieces.append((line[start:match.start()], match.group()))
        start = match.end()
    if start < len(line):
        pieces.append((line[start:], ""))
    output = []
    index = 0
    while index < len(pieces):
        body, ending = pieces[index]
        key = body.strip()
        stop = index + 1
        if _eligible(key):
            while (stop < len(pieces) and pieces[stop - 1][1] in (",", "，")
                   and pieces[stop][0].strip() == key):
                stop += 1
        if stop - index >= 3 and pieces[stop - 1][1] in (",", "，", ".", "。", ";", "；", ""):
            # Preserve the first clause's whitespace and the last punctuation;
            # discarding punctuation from the tail could join distinct ideas.
            output.append(body + pieces[stop - 1][1])
            index = stop
        else:
            # A rejected question/emphasis run is copied once as a whole;
            # rescanning each suffix would make long repeated input quadratic.
            output.extend(part + delimiter for part, delimiter in pieces[index:stop])
            index = stop
    return "".join(output) + trailing


def collapse_adjacent_repetitions(text):
    """Remove only long, neutral, verbatim repeated restarts within one line."""
    # A quote can span lines. Leaving the entire text unchanged when a quote or
    # code delimiter occurs is intentionally conservative and preserves literals.
    if any(mark in text for mark in '\"\'“”‘’「」『』《》〈〉`'):
        return text
    output = []
    reference_block = False
    for line in text.splitlines(keepends=True):
        if not line.strip():
            reference_block = False
        # A colon can introduce an unquoted literal or a data block. Preserve
        # that line and its continuation until a blank paragraph boundary.
        if ":" in line or "：" in line:
            reference_block = True
        output.append(line if reference_block else _clean_line(line))
    return "".join(output)
