"""Writes test/corpus/fuzz5.sql: random calls of the functions whose answers are text built by rules —
date and time with their modifiers, printf/format, the string functions over non-ASCII text, and
numbers turned into text and back — for corpus.py to record what the real SQLite answers.
Deterministic: `python3 tools/fuzz5.py [seed] [count]`."""
import random, sys

seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
count = int(sys.argv[2]) if len(sys.argv) > 2 else 300
r = random.Random(seed)

def pick(*xs): return r.choice(xs)

def timevalue():
    k = r.randrange(8)
    if k == 0: return f"'{r.randint(1, 2999):04d}-{r.randint(1, 12):02d}-{r.randint(1, 31):02d}'"
    if k == 1: return f"'{r.randint(1900, 2100):04d}-{r.randint(1, 12):02d}-{r.randint(1, 28):02d} {r.randint(0, 23):02d}:{r.randint(0, 59):02d}:{r.randint(0, 59):02d}'"
    if k == 2: return f"'{r.randint(1900, 2100)}-{r.randint(1, 12):02d}-{r.randint(1, 28):02d}T{r.randint(0, 23):02d}:{r.randint(0, 59):02d}:{r.randint(0, 59):02d}.{r.randint(0, 999):03d}'"
    if k == 3: return str(r.uniform(2400000, 2500000))[:13]
    if k == 4: return str(r.randint(-10**10, 10**10))
    if k == 5: return f"'{r.randint(0, 23):02d}:{r.randint(0, 59):02d}'"
    if k == 6: return pick("'2024-02-29'", "'2023-02-29'", "'2000-01-01 00:00:00+05:30'", "'2024-12-31T23:59:59Z'", "'now'", "NULL", "'bad'", "'0000-01-01'")
    return f"'{r.randint(1970, 2050)}-{r.randint(1, 12):02d}-{r.randint(1, 28):02d} {r.randint(0, 23):02d}:{r.randint(0, 59):02d}'"

def modifier():
    n = r.randint(-400, 400)
    unit = pick("days", "day", "hours", "minutes", "seconds", "months", "years", "month", "year")
    k = r.randrange(10)
    if k < 4: return f"'{'+' if n >= 0 else ''}{n} {unit}'"
    if k == 4: return pick("'start of month'", "'start of year'", "'start of day'")
    if k == 5: return f"'weekday {r.randint(0, 6)}'"
    if k == 6: return pick("'unixepoch'", "'julianday'", "'auto'", "'localtime'", "'utc'", "'subsec'")
    if k == 7: return f"'{'+' if n >= 0 else '-'}{abs(n) % 24:02d}:{r.randint(0, 59):02d}'"
    if k == 8: return pick("'floor'", "'ceiling'", f"'{r.uniform(-3, 3):.3f} days'")
    return f"'+{r.randint(0, 3)}-{r.randint(0, 11):02d}-{r.randint(0, 28):02d}'"

def q_date():
    fn = pick("date", "time", "datetime", "julianday", "unixepoch")
    mods = ", ".join(modifier() for _ in range(r.randint(0, 3)) if True)
    args = timevalue() + (", " + mods if mods else "")
    # 'now' and localtime depend on the clock and the machine.
    if "'now'" in args or "localtime" in args or "'utc'" in args: args = args.replace("'now'", "'2020-01-01'").replace("'localtime'", "'start of day'").replace("'utc'", "'start of day'")
    return f"SELECT {fn}({args});"

def q_strftime():
    fmt = "".join(pick("%Y", "%m", "%d", "%H", "%M", "%S", "%f", "%j", "%J", "%s", "%w", "%W", "%u", "%U", "%V", "%G", "%g", "%e", "%k", "%l", "%I", "%p", "%P", "%F", "%T", "%R", "%D", "%%", "-", " ", ":") for _ in range(r.randint(1, 5)))
    v = timevalue()
    if "'now'" in v: v = "'2021-06-15 12:34:56'"
    return f"SELECT strftime('{fmt}', {v});"

def number():
    k = r.randrange(8)
    if k == 0: return str(r.randint(-1000, 1000))
    if k == 1: return repr(r.uniform(-1e6, 1e6))
    if k == 2: return pick("0", "-0.0", "1e300", "-1e-300", "9223372036854775807", "-9223372036854775808", "0.1", "123456789.123456789")
    if k == 3: return f"{r.uniform(-10, 10):.{r.randint(0, 9)}f}"
    if k == 4: return f"'{r.randint(-50, 50)}'"
    if k == 5: return pick("'abc'", "'é'", "NULL", "''", "'3.5e2x'", "X'41'")
    if k == 6: return f"{r.uniform(1, 9):.2f}e{r.randint(-20, 20)}"
    return str(r.randint(-10**15, 10**15))

def q_printf():
    spec = "%" + "".join(r.sample(["-", "+", " ", "0", "#", ",", "!"], r.randint(0, 2)))
    if r.randrange(2): spec += str(r.randint(0, 12))
    if r.randrange(2): spec += "." + str(r.randint(0, 8))
    conv = pick("d", "i", "f", "e", "E", "g", "G", "x", "X", "o", "s", "q", "Q", "w", "c", "z", "u")
    fn = pick("printf", "format")
    arg = number()
    # A precision counts bytes without '!', and SQLite then cuts a character in two: text Python's
    # sqlite3 cannot decode.
    if "." in spec and "!" not in spec and conv in "sqQwz" and arg == "'é'": arg = "'abc'"
    return f"SELECT {fn}('[{spec}{conv}]', {arg});"

TEXTS = ["'héllo wörld'", "'ÀÉÎõü'", "'日本語テキスト'", "'emoji 😀 here'", "'MiXeD CaSe'", "'  pad  '", "'a''b'", "''", "NULL", "'ß'", "'İstanbul'", "'x\ty'"]

def q_string():
    t = r.choice(TEXTS)
    k = r.randrange(12)
    if k == 0: return f"SELECT upper({t}), lower({t}), length({t}), octet_length({t});"
    if k == 1: return f"SELECT substr({t}, {r.randint(-6, 8)}, {r.randint(-3, 6)}), substr({t}, {r.randint(-6, 8)});"
    if k == 2: return f"SELECT instr({t}, {r.choice(TEXTS)}), replace({t}, {pick(repr('l'), repr('é'), repr(''), repr('😀'))}, 'X');"
    if k == 3: return f"SELECT trim({t}), ltrim({t}, 'h '), rtrim({t}, 'dé '), trim({t}, 'aé😀 ');"
    if k == 4: return f"SELECT hex({t}), quote({t}), unicode({t}), typeof({t});"
    if k == 5: return f"SELECT {t} LIKE {pick(repr('%é%'), repr('H%'), repr('_é%'), repr('%😀%'), repr('%É%'))}, {t} GLOB {pick(repr('*ö*'), repr('[a-z]*'), repr('?*'), repr('*[^ ]'))};"
    # Not the surrogates, which SQLite passes through as bytes Python's sqlite3 cannot decode.
    if k == 6:
        cp = lambda lo, hi: r.choice([c for c in (r.randint(lo, hi) for _ in range(4)) if not 0xD800 <= c <= 0xDFFF] or [65])
        return f"SELECT char({cp(32, 0x1F700)}, {cp(65, 300)}), unicode(char({cp(1, 0x10FFFF)}));"
    if k == 7: return f"SELECT {t} || {r.choice(TEXTS)}, concat({t}, {number()}), concat_ws('-', {t}, {number()}, NULL);"
    if k == 8: return f"SELECT {t} < {r.choice(TEXTS)}, {t} = {r.choice(TEXTS)} COLLATE NOCASE, {t} COLLATE RTRIM = {r.choice(TEXTS)};"
    if k == 9: return f"SELECT soundex({t});" if False else f"SELECT length(CAST({t} AS BLOB)), CAST(CAST({t} AS BLOB) AS TEXT);"
    if k == 10: return f"SELECT round({number()}, {r.randint(-2, 6)}), round({number()});"
    return f"SELECT CAST({number()} AS TEXT), CAST({number()} AS INTEGER), CAST({number()} AS REAL), CAST({number()} AS NUMERIC);"

kinds = [q_date, q_date, q_date, q_strftime, q_strftime, q_printf, q_printf, q_printf, q_string, q_string]
out = ["-- Generated by tools/fuzz5.py: dates, printf, strings, numbers as text."]
for _ in range(count):
    out.append(r.choice(kinds)())
open("test/corpus/fuzz5.sql", "w").write("\n".join(out) + "\n")
