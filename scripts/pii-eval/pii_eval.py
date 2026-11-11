#!/usr/bin/env python3
"""Builds a labelled corpus for PIIMasker and scores the matches it produced.

    pip install python-stdnum          # test oracle only, never shipped with the app
    python3 pii_eval.py gen OUT_DIR [LABEL=PATH ...]     # real text to scan for false positives
    SILLOG_PII_EVAL_IN=OUT_DIR/corpus.jsonl SILLOG_PII_EVAL_OUT=OUT_DIR/matches.jsonl \
        swift test --filter SillogCoreTests.PIIMaskerEvalTests
    python3 pii_eval.py score OUT_DIR

Valid identifiers are generated here and accepted only when python-stdnum agrees, so the Swift
check-digit code is tested against an independent implementation.
"""
import json, os, random, string, sys
from collections import Counter, defaultdict

from stdnum import iban, luhn
from stdnum.au import tfn
from stdnum.br import cpf
from stdnum.ca import sin
from stdnum.cn import ric
from stdnum.de import idnr
from stdnum.es import dni, nie
from stdnum.fr import nir
from stdnum.in_ import aadhaar, pan
from stdnum.it import codicefiscale
from stdnum.jp import in_ as mynumber
from stdnum.mx import curp
from stdnum.nl import bsn
from stdnum.pl import pesel
from stdnum.se import personnummer

R = random.Random(20261112)
N = 150          # samples per identifier format
UP = string.ascii_uppercase


def d(n): return "".join(R.choice(string.digits) for _ in range(n))
def up(n, chars=UP): return "".join(R.choice(chars) for _ in range(n))
def alnum(n, chars=string.ascii_letters + string.digits): return "".join(R.choice(chars) for _ in range(n))
def ymd(lo=1940, hi=2009): return R.randint(lo, hi), R.randint(1, 12), R.randint(1, 28)
def until(make, ok):
    while True:
        value = make()
        if ok(value): return value
def group(s, sep, sizes):
    out, i = [], 0
    for size in sizes: out.append(s[i:i + size]); i += size
    return sep.join(out)


# ---- valid identifiers: name -> (kind, {variant: (supported, generator)}) ----

def rrn():
    y, m, dd = ymd(); return f"{y % 100:02}{m:02}{dd:02}", f"{R.choice('12' if y < 2000 else '34')}{d(6)}"
def ssn(): return until(lambda: (d(3), d(2), d(4)), lambda p: p[0] not in ("000", "666") and p[1] != "00" and p[2] != "0000")
def cn():
    def make():
        y, m, dd = ymd(); body = R.choice(["110105", "110108", "310104", "440305", "510107", "330106", "320106"]) + f"{y}{m:02}{dd:02}" + d(3)
        return body + ric.calc_check_digit(body)
    return until(make, ric.is_valid)
def jp():
    body = d(11); value = body + mynumber.calc_check_digit(body); assert mynumber.is_valid(value); return value
def hk():
    prefix = up(R.choice([1, 2]), "ABCDEFGHJKLMNPRSTVWXYZ"); digits = d(6)
    values = ([36] if len(prefix) == 1 else []) + [ord(c) - 55 for c in prefix] + [int(c) for c in digits]
    check = (11 - sum(v * w for v, w in zip(values, range(9, 1, -1))) % 11) % 11
    return prefix + digits, "A" if check == 10 else str(check)
def tw():
    letter = R.choice(UP); code = "ABCDEFGHJKLMNPQRSTUVXYWZIO".index(letter) + 10; body = R.choice("12") + d(7)
    total = code // 10 + code % 10 * 9 + sum(int(c) * w for c, w in zip(body, [8, 7, 6, 5, 4, 3, 2, 1]))
    return letter + body + str((10 - total % 10) % 10)
def sg():
    prefix = R.choice("STFG"); digits = d(7)
    total = sum(int(c) * w for c, w in zip(digits, [2, 7, 6, 5, 4, 3, 2])) + (4 if prefix in "TG" else 0)
    return prefix + digits + ("JZIHGFEDCBA" if prefix in "ST" else "XWUTRQPNMLK")[total % 11]
def mx():
    def make():
        y, m, dd = ymd(1940, 1999)
        body = up(1, "BCDFGHJKLMNPRSTVZ") + up(1, "AEIOU") + up(2) + f"{y % 100:02}{m:02}{dd:02}" + R.choice("HM") + R.choice(["DF", "JC", "NL", "MC", "PL", "GT"]) + up(3, "BCDFGHJKLMNPRSTVZ") + R.choice(string.digits)
        return body + curp.calc_check_digit(body)
    return until(make, curp.is_valid)
def nino(): return until(lambda: up(1, "ABCEGHJKLMNOPRSTWXYZ") + up(1, "ABCEGHJKLMNPRSTWXYZ"), lambda p: p not in ("BG", "GB", "NK", "KN", "TN", "NT", "ZZ")) + d(6) + R.choice("ABCD")
def fr():
    def make():
        y, m, _ = ymd(); body = f"{R.choice('12')}{y % 100:02}{m:02}{R.choice(['75', '13', '69', '33', '2A', '2B', '06'])}{R.randint(1, 990):03}{R.randint(1, 999):03}"
        return body + nir.calc_check_digits(body)
    return until(make, nir.is_valid)
def cf():
    def make():
        y, _, dd = ymd(); body = up(6, "BCDFGLMNPRSTV") + f"{y % 100:02}" + R.choice("ABCDEHLMPRST") + f"{dd:02}" + R.choice("AHFLZ") + d(3)
        return body + codicefiscale.calc_check_digit(body)
    return until(make, codicefiscale.is_valid)
def de():
    def make():
        nine = R.sample(string.digits, 9); body = nine + [R.choice(nine)]; R.shuffle(body)
        return "".join(body) + R.choice(string.digits)
    return until(make, idnr.is_valid)
def pl():
    y, m, dd = ymd(); body = f"{y % 100:02}{m + (20 if y >= 2000 else 0):02}{dd:02}{d(4)}"
    value = body + pesel.calc_check_digit(body); assert pesel.is_valid(value); return value
def se():
    def make():
        y, m, dd = ymd(); body = f"{y % 100:02}{m:02}{dd:02}{d(3)}"
        return str(y)[:2], body + luhn.calc_check_digit(body)
    return until(make, lambda p: personnummer.is_valid(p[1][:6] + "-" + p[1][6:]))
def card(length=16): 
    body = R.choice(["4", "51", "52", "53", "54", "55", "35", "6011"] if length == 16 else ["34", "37"])
    body += d(length - 1 - len(body)); return body + luhn.calc_check_digit(body)
def an_iban():
    def make():
        country, bban = R.choice([("DE", d(18)), ("NL", up(4) + d(10)), ("GB", up(4) + d(14)), ("AT", d(16)), ("BE", d(12))])
        return country + iban.calc_check_digits(country + "00" + bban) + bban
    return until(make, iban.is_valid)
def email(): return f"{alnum(R.randint(3, 9), string.ascii_lowercase)}{R.choice(['', '.kim', '_dev', '+news', '99'])}@{R.choice(['gmail.com', 'naver.com', 'example.co.kr', 'corp.example.org', 'mail.example.io'])}"
def private_key(): return "-----BEGIN RSA PRIVATE KEY-----\n" + "\n".join(alnum(64) for _ in range(3)) + "\n-----END RSA PRIVATE KEY-----"

E = {  # name: (kind, {variant: (supported, generator returning text or (prefix, secret))})
    "kr-rrn": ("ID", {"hyphen": (1, lambda: "-".join(rrn())), "bare": (0, lambda: "".join(rrn()))}),
    "us-ssn": ("ID", {"hyphen": (1, lambda: "-".join(ssn())), "space": (0, lambda: " ".join(ssn())), "bare": (0, lambda: "".join(ssn()))}),
    "cn-ric": ("ID", {"plain": (1, cn), "lower-x": (1, lambda: cn().lower())}),
    "jp-mynumber": ("ID", {"labelled": (1, lambda: ("マイナンバー: ", jp())), "bare": (0, jp), "space": (1, lambda: group(jp(), " ", [4, 4, 4])), "hyphen": (1, lambda: group(jp(), "-", [4, 4, 4]))}),
    "in-aadhaar": ("ID", {"labelled": (1, lambda: ("Aadhaar No. ", until(lambda: R.choice("23456789") + d(11), aadhaar.is_valid))),
                          "bare": (0, lambda: until(lambda: R.choice("23456789") + d(11), aadhaar.is_valid)),
                          "space": (1, lambda: group(until(lambda: R.choice("23456789") + d(11), aadhaar.is_valid), " ", [4, 4, 4]))}),
    "in-pan": ("ID", {"plain": (1, lambda: until(lambda: up(3) + R.choice("PCHFATBLJG") + up(1) + d(4) + up(1), pan.is_valid))}),
    "hk-hkid": ("ID", {"paren": (1, lambda: "{}({})".format(*hk())), "plain": (1, lambda: "".join(hk()))}),
    "tw-id": ("ID", {"plain": (1, tw)}),
    "sg-nric": ("ID", {"plain": (1, sg)}),
    "ca-sin": ("ID", {"hyphen": (1, lambda: group(until(lambda: d(9), sin.is_valid), "-", [3, 3, 3])), "space": (1, lambda: group(until(lambda: d(9), sin.is_valid), " ", [3, 3, 3])),
                      "bare": (0, lambda: until(lambda: d(9), sin.is_valid))}),
    "mx-curp": ("ID", {"plain": (1, mx)}),
    "br-cpf": ("ID", {"dotted": (1, lambda: (v := until(lambda: d(11), cpf.is_valid))[:3] + "." + v[3:6] + "." + v[6:9] + "-" + v[9:]),
                      "bare": (1, lambda: until(lambda: d(11), cpf.is_valid))}),
    "gb-nino": ("ID", {"compact": (1, nino), "spaced": (1, lambda: group(nino(), " ", [2, 2, 2, 2, 1]))}),
    "fr-nir": ("ID", {"compact": (1, fr), "spaced": (1, lambda: group(fr(), " ", [1, 2, 2, 2, 3, 3, 2]))}),
    "it-cf": ("ID", {"plain": (1, cf)}),
    "es-dni": ("ID", {"dni": (1, lambda: (b := d(8)) + dni.calc_check_digit(b)), "nie": (1, lambda: (b := R.choice("XYZ") + d(7)) + nie.calc_check_digit(b))}),
    "de-idnr": ("ID", {"bare": (1, de), "spaced": (0, lambda: group(de(), " ", [2, 3, 3, 3]))}),
    "pl-pesel": ("ID", {"bare": (1, pl)}),
    "se-pnr": ("ID", {"short": (1, lambda: (p := se())[1][:6] + "-" + p[1][6:]), "long": (1, lambda: (p := se())[0] + p[1][:6] + "-" + p[1][6:]), "bare": (0, lambda: se()[1])}),
    "nl-bsn": ("ID", {"labelled": (1, lambda: ("BSN ", until(lambda: d(9), bsn.is_valid))), "bare": (0, lambda: until(lambda: d(9), bsn.is_valid))}),
    "au-tfn": ("ID", {"labelled": (1, lambda: ("TFN: ", until(lambda: d(9), tfn.is_valid))), "bare": (0, lambda: until(lambda: d(9), tfn.is_valid)), "spaced": (1, lambda: group(until(lambda: d(9), tfn.is_valid), " ", [3, 3, 3]))}),
    "card": ("CARD", {"bare": (1, card), "hyphen": (1, lambda: group(card(), "-", [4, 4, 4, 4])), "space": (1, lambda: group(card(), " ", [4, 4, 4, 4])),
                      "amex": (1, lambda: group(card(15), " ", [4, 6, 5]))}),
    "iban": ("ACCOUNT", {"compact": (1, an_iban), "grouped": (1, lambda: group(v := an_iban(), " ", [4] * (len(v) // 4 + 1)).strip())}),
    "kr-account": ("ACCOUNT", {"6-2-6": (1, lambda: f"{d(6)}-{d(2)}-{d(6)}"), "3-6-2-3": (1, lambda: f"{d(3)}-{d(6)}-{d(2)}-{d(3)}"), "4-3-6": (1, lambda: f"{d(4)}-{d(3)}-{d(6)}"),
                               "bare": (0, lambda: d(R.choice([11, 12, 13, 14])))}),
    "phone": ("PHONE", {
        "kr-mobile-hyphen": (1, lambda: f"010-{d(4)}-{d(4)}"), "kr-mobile-bare": (1, lambda: f"010{d(8)}"), "kr-mobile-space": (1, lambda: f"010 {d(4)} {d(4)}"),
        "kr-mobile-dot": (1, lambda: f"010.{d(4)}.{d(4)}"), "kr-mobile-+82": (1, lambda: f"+82 10-{d(4)}-{d(4)}"), "kr-landline": (1, lambda: f"{R.choice(['02', '031', '051', '064'])}-{d(R.choice([3, 4]))}-{d(4)}"),
        "us-hyphen": (1, lambda: f"{R.randint(201, 989)}-{R.randint(200, 999)}-{d(4)}"), "us-paren": (1, lambda: f"({R.randint(201, 989)}) {R.randint(200, 999)}-{d(4)}"),
        "us-dot": (1, lambda: f"{R.randint(201, 989)}.{R.randint(200, 999)}.{d(4)}"), "us-+1": (1, lambda: f"+1 {R.randint(201, 989)} {R.randint(200, 999)} {d(4)}"),
        "us-bare": (0, lambda: f"{R.randint(201, 989)}{R.randint(200, 999)}{d(4)}"),
        "uk-+44": (1, lambda: f"+44 20 {d(4)} {d(4)}"), "jp-+81": (1, lambda: f"+81 90-{d(4)}-{d(4)}"), "cn-+86": (1, lambda: f"+86 138 {d(4)} {d(4)}"),
        "de-+49": (1, lambda: f"+49 30 {d(7)}"), "fr-+33": (1, lambda: f"+33 1 {d(2)} {d(2)} {d(2)} {d(2)}"), "in-+91": (1, lambda: f"+91 98{d(3)} {d(5)}"),
        "jp-local": (1, lambda: f"090-{d(4)}-{d(4)}"), "uk-local": (0, lambda: f"020 {d(4)} {d(4)}"), "de-local": (0, lambda: f"030 {d(7)}"),
        "fr-local": (0, lambda: f"01 {d(2)} {d(2)} {d(2)} {d(2)}"), "cn-local": (0, lambda: f"138 {d(4)} {d(4)}"), "in-local": (0, lambda: f"98{d(3)} {d(5)}")}),
    "email": ("EMAIL", {"plain": (1, email)}),
    "secret": ("SECRET", {
        "openai": (1, lambda: "sk-proj-" + alnum(40)), "anthropic": (1, lambda: "sk-ant-api03-" + alnum(48)), "github": (1, lambda: "ghp_" + alnum(36)),
        "github-pat": (1, lambda: "github_pat_" + alnum(40)), "aws-id": (1, lambda: "AKIA" + up(16, UP + string.digits)), "slack": (1, lambda: f"xoxb-{d(12)}-{d(12)}-{alnum(24)}"),
        "google": (1, lambda: "AIza" + alnum(35)), "jwt": (1, lambda: f"eyJ{alnum(20)}.eyJ{alnum(40)}.{alnum(43)}"), "private-key": (1, private_key),
        "env": (1, lambda: ("DB_PASSWORD=", alnum(10) + d(3))), "yaml": (1, lambda: ("api_key: ", alnum(20) + d(4))), "json": (1, lambda: ('"token": "', alnum(24) + d(2))),
        "korean": (1, lambda: ("비밀번호: ", alnum(8) + d(2))), "stripe": (1, lambda: "sk_live_" + alnum(24)), "aws-secret": (0, lambda: alnum(40, string.ascii_letters + string.digits + "/+")),
        "bearer": (1, lambda: ("Authorization: Bearer ", alnum(40))), "hex-token": (0, lambda: alnum(32, "0123456789abcdef")), "password-no-digit": (0, lambda: ("password: ", alnum(12, string.ascii_letters)))}),
    "address": ("ADDRESS", {
        "kr-road": (1, lambda: f"서울특별시 {R.choice(['강남구 테헤란로', '마포구 월드컵북로', '종로구 세종대로', '송파구 올림픽로'])} {R.randint(1, 400)}"),
        "kr-road-unit": (1, lambda: f"경기도 성남시 분당구 판교역로 {R.randint(1, 300)}, {R.randint(101, 120)}동 {R.randint(101, 2504)}호"),
        "us": (1, lambda: f"{R.randint(100, 9999)} {R.choice(['Market Street', 'Amphitheatre Parkway', 'Main St', 'Broadway'])}, {R.choice(['San Francisco, CA 94103', 'Mountain View, CA 94043', 'New York, NY 10012'])}"),
        "uk": (1, lambda: f"{R.randint(1, 200)} {R.choice(['Baker Street', 'High Street', 'Kings Road'])}, London {R.choice(['NW1 6XE', 'SW3 4LY', 'E1 6AN'])}"),
        "jp": (1, lambda: f"東京都{R.choice(['千代田区丸の内', '渋谷区神南', '港区六本木'])}{R.randint(1, 6)}-{R.randint(1, 20)}-{R.randint(1, 20)}"),
        "de": (1, lambda: f"{R.choice(['Friedrichstraße', 'Hauptstraße', 'Unter den Linden'])} {R.randint(1, 200)}, {R.choice(['10117 Berlin', '80331 München'])}")}),
}

CARRIERS = [
    "{}", "번호는 {} 입니다.", "번호는{}입니다", "연락처: {}", "({})", "「{}」로 보냈다", "value={}&next=1", 'user: {"value": "{}", "ok": true}', "alice,{},seoul",
    "| name | {} | active |", "[14:05:33] INFO lookup {} done", "Please confirm {} before Friday.", "My number is {}.", "{} — updated", "ID:{}", "→ {}\n다음 줄",
    "お客様番号は{}です", "您的号码是{}。", "Su número es {}, gracias.", "Kennung: {} (bitte prüfen)", "<td>{}</td>", "note = '{}'", "#{} 참고", "re: {}, thanks",
]


def u16(s): return len(s.encode("utf-16-le")) // 2


def placed(carrier, name, variant):
    kind, variants = E[name]; supported, make = variants[variant]
    made = make(); prefix, value = made if isinstance(made, tuple) else ("", made)
    head, tail = carrier.split("{}", 1)
    start = u16(head + prefix)
    return head + prefix + value + tail, {"start": start, "end": start + u16(value), "kind": kind, "type": name, "variant": variant, "supported": bool(supported)}


# ---- text that must not be masked ----

LOOKALIKES = {
    "date-iso": lambda: "{}-{:02}-{:02}".format(*ymd(1990, 2030)), "date-dot": lambda: "{}.{:02}.{:02}".format(*ymd(1990, 2030)), "date-slash": lambda: "{1:02}/{2:02}/{0}".format(*ymd(1990, 2030)),
    "date-compact": lambda: "{}{:02}{:02}".format(*ymd(1990, 2030)), "datetime": lambda: "{}-{:02}-{:02} {:02}:{:02}:{:02}".format(*ymd(2020, 2030), R.randint(0, 23), R.randint(0, 59), R.randint(0, 59)),
    "datetime-compact": lambda: "{}{:02}{:02}{:02}{:02}{:02}".format(*ymd(2020, 2030), R.randint(0, 23), R.randint(0, 59), R.randint(0, 59)),
    "iso8601": lambda: "{}-{:02}-{:02}T{:02}:{:02}:00+09:00".format(*ymd(2020, 2030), R.randint(0, 23), R.randint(0, 59)),
    "unix-seconds": lambda: str(R.randint(1_500_000_000, 1_900_000_000)), "unix-millis": lambda: str(R.randint(1_500_000_000_000, 1_900_000_000_000)),
    "time-range": lambda: f"{R.randint(0, 23):02}:{R.randint(0, 59):02}-{R.randint(0, 23):02}:{R.randint(0, 59):02}", "duration": lambda: f"{R.randint(1, 99)}m {R.randint(0, 59)}s",
    "order-number": lambda: "ORD-{}{:02}{:02}-{}".format(*ymd(2020, 2030), d(6)), "invoice": lambda: f"INV-{d(4)}-{d(5)}", "ticket": lambda: f"{up(R.randint(2, 5))}-{R.randint(1, 99999)}",
    "tracking-kr": lambda: d(R.choice([12, 13])), "tracking-ups": lambda: "1Z" + up(6, UP + string.digits) + d(10), "isbn13": lambda: f"978-89-{d(4)}-{d(3)}-{d(1)}", "isbn10": lambda: f"89-{d(4)}-{d(3)}-{d(1)}",
    "kr-business-number": lambda: f"{d(3)}-{d(2)}-{d(5)}", "zip-kr": lambda: d(5), "zip-us-plus4": lambda: f"{d(5)}-{d(4)}", "version": lambda: f"{R.randint(0, 30)}.{R.randint(0, 99)}.{R.randint(0, 999)}",
    "version-build": lambda: f"v{R.randint(1, 9)}.{R.randint(0, 20)}.{R.randint(0, 20)}-{d(R.choice([3, 5, 8]))}", "ipv4": lambda: ".".join(str(R.randint(1, 254)) for _ in range(4)),
    "ipv4-port": lambda: f"10.0.{R.randint(0, 255)}.{R.randint(1, 254)}:{R.randint(1024, 65535)}", "ipv6": lambda: ":".join(alnum(4, "0123456789abcdef") for _ in range(8)),
    "mac": lambda: ":".join(alnum(2, "0123456789ABCDEF") for _ in range(6)), "uuid": lambda: "-".join(alnum(n, "0123456789abcdef") for n in (8, 4, 4, 4, 12)),
    "git-sha": lambda: alnum(R.choice([7, 40]), "0123456789abcdef"), "sha256": lambda: alnum(64, "0123456789abcdef"), "hex-color": lambda: "#" + alnum(6, "0123456789ABCDEF"),
    "price-krw": lambda: f"{R.randint(1, 999)},{d(3)},{d(3)}원", "price-usd": lambda: f"${R.randint(1, 999)},{d(3)}.{d(2)}", "percent": lambda: f"{R.randint(0, 99)}.{d(2)}%",
    "coordinates": lambda: f"{R.uniform(33, 43):.6f}, {R.uniform(124, 132):.6f}", "math": lambda: f"{d(4)} - {d(4)} = {d(4)}", "range": lambda: f"{R.randint(1, 999)}-{R.randint(1, 999)}",
    "range-3": lambda: f"{d(3)}-{d(3)}-{d(3)}-{d(3)}-{d(3)}", "file-line": lambda: f"{R.choice(['main', 'AppState', 'index'])}.swift:{R.randint(1, 2000)}:{R.randint(1, 120)}",
    "localhost": lambda: f"http://localhost:{R.randint(1024, 65535)}/v1/items/{R.randint(1, 10**9)}", "url-long-id": lambda: f"https://example.com/status/{d(19)}",
    "url-numeric-path": lambda: f"https://example.com/{d(4)}/{d(2)}/{d(2)}/post-{d(6)}", "issue": lambda: f"#{R.randint(1, 99999)}", "sku": lambda: f"{up(2)}-{d(4)}-{d(4)}",
    "model-number": lambda: f"{up(2)}-{up(1)}{d(3)}{up(1)}", "serial-alnum": lambda: up(3) + alnum(9, UP + string.digits), "serial-letter-digits": lambda: up(1) + d(9), "serial-2letters-digits": lambda: up(2) + d(7),
    "flight": lambda: f"{up(2)}{R.randint(1, 9999)}", "license-plate-kr": lambda: f"{d(2)}가 {d(4)}", "student-id": lambda: f"20{d(2)}{d(R.choice([5, 6]))}",
    "byte-size": lambda: f"{R.randint(1, 10**12):,} bytes", "big-count": lambda: f"{R.randint(10**6, 10**12)} rows", "float": lambda: f"{R.uniform(0, 1e6):.9f}",
    "sci": lambda: f"{R.uniform(1, 9):.5f}e-{R.randint(1, 20)}", "base64": lambda: alnum(R.choice([24, 44, 88]), string.ascii_letters + string.digits + "+/") + "==",
    "youtube": lambda: f"https://youtu.be/{alnum(11, string.ascii_letters + string.digits + '-_')}", "doi": lambda: f"10.{d(4)}/{alnum(8, string.ascii_lowercase + string.digits)}.{d(4)}",
    "arxiv": lambda: f"arXiv:{d(4)}.{d(5)}", "swift-code": lambda: f"let limit = {R.randint(1, 10**7)}; frame(width: {R.randint(1, 2000)}, height: {R.randint(1, 2000)})",
    "sql": lambda: f"SELECT * FROM events WHERE id IN ({d(9)}, {d(9)}) AND ts > {d(10)}", "json-ids": lambda: f'{{"id": {d(R.randint(8, 18))}, "parent": {d(R.randint(8, 18))}, "n": {R.randint(0, 99)}}}',
    "css": lambda: f"margin: {R.randint(0, 99)}px {R.randint(0, 99)}px; z-index: {d(R.randint(3, 9))}", "phone-ext": lambda: f"ext. {d(4)}", "luhn-fail-card": lambda: until(lambda: group(d(16), "-", [4] * 4), lambda v: not luhn.is_valid(v.replace("-", ""))),
    "key-prose": lambda: R.choice(["token: 입력 토큰 수", "password: (hidden)", "secret: see vault", "api_key: <YOUR_KEY>", "token = response.json()"]),
    "prose-ko": lambda: R.choice(["중간보고서 3장 초안을 작성하고 결과 표 2개를 추가했다.", "회의는 오후 3시 30분에 12층에서 열린다.", "총 1,204건 중 37건이 실패했다 (3.1%)."]),
    "prose-en": lambda: R.choice(["Merged 14 commits into main after 3 reviews.", "The build took 2 min 41 s on 8 cores.", "See chapter 12, pages 345-389, figure 4.2."]),
}

RANDOM_SHAPES = {f"digits-{n}": (lambda n=n: d(n)) for n in range(6, 20)}
RANDOM_SHAPES |= {"4-4-4": lambda: f"{d(4)} {d(4)} {d(4)}", "3-3-3": lambda: f"{d(3)}-{d(3)}-{d(3)}", "3 3 3": lambda: f"{d(3)} {d(3)} {d(3)}",
                  "4-4-4-4": lambda: f"{d(4)}-{d(4)}-{d(4)}-{d(4)}", "3.3.3-2": lambda: f"{d(3)}.{d(3)}.{d(3)}-{d(2)}", "letter+9": lambda: up(1) + d(9), "5L4D1L": lambda: up(5) + d(4) + up(1),
                  "8D1L": lambda: d(8) + up(1), "L7D1L": lambda: up(1) + d(7) + up(1), "L6D1": lambda: up(1) + d(7), "16L-D mix": lambda: up(6) + d(2) + up(1) + d(2) + up(1) + d(3) + up(1)}
# Shapes that are valid by format alone, so random digits cannot be told apart from a real number.
INHERENT = {"ssn-shaped": lambda: "-".join(ssn()), "nanp-shaped": lambda: f"{d(3)}-{d(3)}-{d(4)}", "rrn-shaped": lambda: f"{d(6)}-{R.choice('1234')}{d(6)}", "kr-account-shaped": lambda: f"{d(4)}-{d(4)}-{d(4)}"}
CHECKED = ["cn-ric", "jp-mynumber", "in-aadhaar", "hk-hkid", "tw-id", "sg-nric", "ca-sin", "mx-curp", "br-cpf", "fr-nir", "es-dni", "de-idnr", "pl-pesel", "se-pnr", "nl-bsn", "au-tfn", "card", "iban"]


def corrupt(value):
    positions = [i for i, c in enumerate(value) if c.isdigit()]; i = R.choice(positions)
    return value[:i] + R.choice([c for c in string.digits if c != value[i]]) + value[i + 1:]


def generate(out, real):
    items = []
    def add(set_, text, gold=(), cat=""): items.append({"id": len(items), "set": set_, "cat": cat, "text": text, "gold": list(gold)})
    for name, (_, variants) in E.items():
        for variant in variants:
            for i in range(N):
                text, gold = placed(CARRIERS[i % len(CARRIERS)], name, variant); add("pos", text, [gold], f"{name}/{variant}")
    names = [(n, v) for n, (_, vs) in E.items() for v, (ok, _) in vs.items() if ok and n != "secret"]
    for _ in range(600):                       # several identifiers in one line
        text, gold = "", []
        for name, variant in R.sample(names, R.randint(2, 3)):
            piece, g = placed(R.choice(["{}", "({})", "id {}"]), name, variant); offset = u16(text)
            g["start"] += offset; g["end"] += offset; gold.append(g); text += piece + R.choice([", ", " / ", " 그리고 ", "; "])
        add("multi", text, gold)
    for cat, make in LOOKALIKES.items():
        for i in range(200): add("look", make().join(CARRIERS[i % len(CARRIERS)].split("{}", 1)), cat=cat)
    for cat, make in RANDOM_SHAPES.items():
        for _ in range(3000): add("rand", "ref " + make(), cat=cat)
    for cat, make in INHERENT.items():
        for _ in range(500): add("inherent", "ref " + make(), cat=cat)
    for name in CHECKED:
        make = next(g for ok, g in E[name][1].values() if ok)
        for _ in range(300):
            made = make(); add("corrupt", "ref " + (made[0] + corrupt(made[1]) if isinstance(made, tuple) else corrupt(made)), cat=name)
    for spec in real:
        label, path = spec.split("=", 1)
        files = [path] if os.path.isfile(path) else sorted(os.path.join(r, f) for r, _, fs in os.walk(path) for f in fs)
        for file in files:
            try: lines = open(file, encoding="utf-8").read().split("\n")
            except (UnicodeDecodeError, OSError): continue
            for number, line in enumerate(lines):
                if line.strip(): add("real:" + label, line[:4000], cat=f"{file}:{number + 1}")
    with open(os.path.join(out, "corpus.jsonl"), "w") as f:
        for item in items: f.write(json.dumps(item, ensure_ascii=False) + "\n")
    print(len(items), "items,", dict(Counter(i["set"] for i in items)))


def wilson(k, n):
    if n == 0: return (0, 0)
    z = 1.96; p = k / n; centre = (p + z * z / 2 / n) / (1 + z * z / n); half = z * ((p * (1 - p) / n + z * z / 4 / n / n) ** 0.5) / (1 + z * z / n)
    return (centre - half, centre + half)


def score(out):
    corpus = [json.loads(line) for line in open(os.path.join(out, "corpus.jsonl"))]
    matches = {m["id"]: m["matches"] for m in map(json.loads, open(os.path.join(out, "matches.jsonl")))}
    recall = defaultdict(Counter); fp = defaultdict(Counter); totals = Counter(); chars = Counter(); tp = Counter(); fp_rule = Counter(); samples = defaultdict(list); misses = []
    for item in corpus:
        preds = matches.get(item["id"], []); set_ = item["set"]; totals[set_] += 1; chars[set_] += len(item["text"]); units = item["text"].encode("utf-16-le")
        for g in item["gold"]:
            over = [p for p in preds if p["start"] < g["end"] and p["end"] > g["start"]]
            def covers(p):
                if g["kind"] == "ADDRESS": return min(p["end"], g["end"]) - max(p["start"], g["start"]) >= 0.5 * (g["end"] - g["start"])
                return p["start"] <= g["start"] and p["end"] >= g["end"]
            full = [p for p in over if covers(p)]
            result = "typed" if any(p["kind"] == g["kind"] for p in full) else "other-kind" if full else "partial" if over else "missed"
            key = (g["type"], g["variant"], g["supported"]); recall[key][result] += 1; recall[key]["n"] += 1
            if g["supported"] and result in ("partial", "missed"): misses.append((g["type"], g["variant"], result, item["text"][:120].replace("\n", " ")))
        for p in preds:
            if any(p["start"] < g["end"] and p["end"] > g["start"] for g in item["gold"]):
                if set_ in ("pos", "multi"): tp[p["rule"]] += 1
                continue
            fp[set_][(item["cat"] if not set_.startswith("real") else "", p["rule"])] += 1
            if set_ in ("pos", "multi", "look"): fp_rule[p["rule"]] += 1
            if len(samples[(set_, p["rule"])]) < 400: samples[(set_, p["rule"])].append((item["cat"], units[p["start"] * 2:p["end"] * 2].decode("utf-16-le"), item["text"][:160]))

    def pct(k, n): return f"{100 * k / n:5.1f}%" if n else "   n/a"
    print("\n== Recall by identifier format (masked = fully covered by any tag) ==")
    print(f"{'type/variant':34} {'n':>5} {'masked':>7} {'typed':>7} {'partial':>7} {'missed':>6}")
    agg = defaultdict(Counter)
    for (name, variant, supported), c in sorted(recall.items(), key=lambda kv: (not kv[0][2], kv[0][0], kv[0][1])):
        masked = c["typed"] + c["other-kind"]
        print(f"{name + '/' + variant + ('' if supported else ' *'):34} {c['n']:5} {pct(masked, c['n']):>7} {pct(c['typed'], c['n']):>7} {c['partial']:7} {c['missed']:6}")
        for scope in ("supported" if supported else "unsupported", "all"):
            agg[(scope, E[name][0])].update({"n": c["n"], "masked": masked, "typed": c["typed"]}); agg[(scope, "ALL")].update({"n": c["n"], "masked": masked, "typed": c["typed"]})
    print("* = format the masker does not claim to handle\n\n== Recall by kind ==")
    for (scope, kind), c in sorted(agg.items()):
        lo, hi = wilson(c["masked"], c["n"]); print(f"{scope:12} {kind:8} n={c['n']:6} masked {pct(c['masked'], c['n'])} (95% CI {100 * lo:.1f}-{100 * hi:.1f})  typed {pct(c['typed'], c['n'])}")

    print("\n== Benchmark precision by rule (positives + multi + look-alikes) ==")
    all_tp, all_fp = sum(tp.values()), sum(fp_rule.values())
    for rule in sorted(set(tp) | set(fp_rule)): print(f"{rule:14} TP {tp[rule]:6} FP {fp_rule[rule]:5} precision {pct(tp[rule], tp[rule] + fp_rule[rule])}")
    s = agg[("supported", "ALL")]; r = s["masked"] / s["n"]; p = all_tp / (all_tp + all_fp)
    print(f"{'ALL':14} TP {all_tp:6} FP {all_fp:5} precision {pct(all_tp, all_tp + all_fp)}  recall(supported) {100 * r:.1f}%  F1 {100 * 2 * p * r / (p + r):.1f}%")

    for set_ in sorted(fp):
        if set_ in ("pos", "multi"): continue
        print(f"\n== False positives in set '{set_}' ({totals[set_]} items, {chars[set_]:,} chars) ==")
        if set_.startswith("real"):
            by_rule = Counter()
            for (_, rule), n in fp[set_].items(): by_rule[rule] += n
            for rule, n in by_rule.most_common(): print(f"{rule:14} {n:6}  {1e5 * n / chars[set_]:.2f} per 100k chars")
            print(f"{'ALL':14} {sum(by_rule.values()):6}  {1e5 * sum(by_rule.values()) / chars[set_]:.2f} per 100k chars")
        else:
            per_cat = Counter(i["cat"] for i in corpus if i["set"] == set_); hit = defaultdict(Counter)
            for (cat, rule), n in fp[set_].items(): hit[cat][rule] += n
            for cat in sorted(hit, key=lambda c: -sum(hit[c].values())):
                print(f"{cat:24} {sum(hit[cat].values()):5}/{per_cat[cat]:5} {pct(sum(hit[cat].values()), per_cat[cat])}  " + ", ".join(f"{r}:{n}" for r, n in hit[cat].most_common()))
            clean = [c for c in per_cat if c not in hit]
            print(f"no false positives in {len(clean)} of {len(per_cat)} categories")
    with open(os.path.join(out, "misses.tsv"), "w") as f:
        for row in misses: f.write("\t".join(row) + "\n")
    with open(os.path.join(out, "false_positives.tsv"), "w") as f:
        for (set_, rule), rows in sorted(samples.items()):
            for cat, value, context in rows: f.write("\t".join([set_, rule, cat, value, context.replace("\t", " ").replace("\n", " ")]) + "\n")


if __name__ == "__main__":
    generate(sys.argv[2], sys.argv[3:]) if sys.argv[1] == "gen" else score(sys.argv[2])
