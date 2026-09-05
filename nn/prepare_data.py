#!/usr/bin/env python3
"""
Готовит корпус для обучения QSNet. Всё складывается в nn/data/:

  corpus.tsv   app<TAB>вес<TAB>строка текста      — предложения/команды с контекстом
  words.tsv    lang<TAB>вес<TAB>слово             — слова без контекста (частотные, выученные)

Источники (что недоступно — пропускается с предупреждением):
  * Tatoeba, предложения ru/en (CC-BY)             — живой текст с контекстом
  * OpenSubtitles 50k частотные списки ru/en        — покрытие слов
  * генератор терминальных строк                   — команды, флаги, пути, домены (app=terminal)
  * генератор/скан кода (--code-dir, по умолчанию сам репозиторий QSwitcher)   (app=code)
  * data/personal.txt — свои фразы: `ru<TAB>днс в конфиге` / `en<TAB>dns config` (3-й столбец — app)
  * --learned learned.json приложения: force/stop → слова с большим весом

Запуск на маке (см. README):  python3 prepare_data.py
"""
import argparse
import bz2
import json
import os
import random
import re
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qsnet  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")

TATOEBA = {
    "ru": "https://downloads.tatoeba.org/exports/per_language/rus/rus_sentences.tsv.bz2",
    "en": "https://downloads.tatoeba.org/exports/per_language/eng/eng_sentences.tsv.bz2",
}
FREQ = {
    "ru": "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/ru/ru_50k.txt",
    "en": "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_50k.txt",
}


def log(*a):
    print(*a, flush=True)


def fetch(url, dest):
    if os.path.exists(dest) and os.path.getsize(dest) > 1024:
        return True
    log(f"  качаю {url}")
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "QSwitcher-nn/1.0"})
        with urllib.request.urlopen(req, timeout=120) as r, open(dest + ".part", "wb") as f:
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
        os.replace(dest + ".part", dest)
        return True
    except Exception as e:  # noqa: BLE001
        log(f"  ⚠️  не скачалось: {e}")
        return False


# ------------------------------------------------------------------ Tatoeba

def load_tatoeba(lang, limit):
    dest = os.path.join(DATA, f"tatoeba-{lang}.tsv.bz2")
    if not fetch(TATOEBA[lang], dest):
        return []
    out = []
    with bz2.open(dest, "rt", encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            text = parts[2].strip()
            if 2 <= len(text.split()) <= 25:
                out.append(text)
    random.shuffle(out)
    return out[:limit]


# ------------------------------------------------------------------ частотные списки

def load_freq(lang, limit):
    dest = os.path.join(DATA, f"freq-{lang}.txt")
    if not fetch(FREQ[lang], dest):
        return []
    out = []
    with open(dest, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) != 2:
                continue
            w, n = parts[0], int(parts[1])
            if qsnet.word_lang(w) != lang or qsnet.to_keys(w) is None:
                continue
            out.append((w, n))
            if len(out) >= limit:
                break
    return out


# ------------------------------------------------------------------ терминал

CMDS = """ls cd pwd cat tail head less more grep egrep awk sed cut sort uniq wc tr xargs find locate which whereis
mkdir rmdir rm cp mv ln touch chmod chown chgrp stat file du df mount umount lsblk fdisk
tar gzip gunzip zip unzip xz bzip2 7z
ssh scp sftp rsync curl wget ping dig nslookup host traceroute mtr nc netstat ss ip ifconfig iptables nft ufw
systemctl journalctl service crontab at nohup screen tmux
apt apt-get dpkg dnf yum pacman brew pip pip3 python3 python node npm npx yarn cargo go dotnet swift gh git
docker podman kubectl compose
nginx certbot openssl gpg sha256sum md5sum base64 xxd hexdump
ps top htop kill killall pkill pgrep nice renice uptime free vmstat iostat lsof strace
useradd usermod passwd sudo su whoami id groups hostname hostnamectl timedatectl date cal
echo printf export env set unset alias source exec eval read test
nano vim vi micro
xray x-ui awg wg wg-quick amneziawg mihomo xkeen sing-box clash unbound adguardhome dnsmasq resolvectl
sysctl modprobe lsmod dmesg reboot shutdown poweroff
make cmake gcc clang ld ar strip objdump nm ldd
jq yq sqlite3 psql mysql redis-cli
Get-ChildItem Get-Process Get-Item Get-Content Set-Location Copy-Item Move-Item Remove-Item Expand-Archive Compress-Archive
Stop-Process Start-Process Wait-Process Test-Path Select-String Invoke-WebRequest Import-Module Get-Service Restart-Service
taskkill tasklist ipconfig netsh sfc dism reg schtasks powershell cmd wmic dir del copy move ren type findstr""".split()

FLAGS = """-l -la -lah -a -r -rf -R -f -v -vv -h -n -p -i -e -x -c -s -t -u -d -o -q -y -z -A -L -S -X -P -N -E -F -H
--help --version --verbose --quiet --force --recursive --all --dry-run --no-cache --follow --lines --since --until --unit
--user --group --output --input --config --port --host --name --tag --file --dir --path --json --yaml --raw --pretty
--enable --disable --status --restart --reload --start --stop --install --remove --purge --update --upgrade --list
--depth --branch --message --amend --force-with-lease --rebase --squash --hard --soft --cached --global --local
-Recurse -Force -Path -Name -Filter -Include -Exclude -Encoding -ErrorAction -Confirm -WhatIf -Id -ComputerName""".split()

WORDS = """dns dhcp ntp ssh sshd ssl tls http https tcp udp ip ipv4 ipv6 wan lan vpn proxy socks vless vmess trojan reality
shadowsocks wireguard awg xray mihomo clash sing-box tun tap route routes gateway nat masquerade firewall iptables nftables
nginx apache caddy certbot letsencrypt acme cert certificate key pem crt csr fullchain privkey
docker container image volume network compose swarm kubernetes pod deployment service ingress
systemd unit timer socket target journal syslog logrotate cron
config conf json yaml yml toml ini env dotenv secrets token password passwd user users group groups root sudo admin
server client host hosts domain subdomain zone record resolver resolv upstream backend frontend
port ports listen bind address addr subnet mask cidr mtu keepalive timeout retry retries
install update upgrade remove purge clean autoremove build compile link run start stop restart reload status enable disable
log logs debug trace info warn warning error errors fatal panic verbose quiet silent
branch commit push pull fetch merge rebase checkout clone remote origin main master head tag release stash diff
main src bin lib etc var opt tmp home usr local share dev proc sys mnt media boot
sources resources build dist out target node_modules vendor
readme license makefile dockerfile gitignore package cargo swift csproj sln
keenetic router modem switch bridge vlan wifi ssid wpa
adguard unbound dnsmasq doh dot dnscrypt blocklist allowlist filter filters
telegram mtproto mtproxy bot api webhook
true false null none default auto on off yes no ok
version help usage example examples test tests spec bench""".split()

RU_COMMIT = """фикс правка баг ошибка починил добавил убрал удалил обновил версия релиз рефакторинг перенос
настройка конфиг сервер клиент раскладка свап слово словарь контекст сеть веса обучение проверка лог
скрипт установка меню трей хоткей выделение буфер журнал синк права подпись автообновление""".split()

TLDS = ["com", "net", "org", "ru", "io", "dev", "gs", "me", "app", "cloud"]
HOSTS = ["srv", "vps", "node", "gw", "dns", "vpn", "proxy", "edge", "api", "mail", "web", "db", "nl", "fi", "us", "ru"]


def rnd_domain():
    return f"{random.choice(HOSTS)}{random.choice(['', '1', '2', '-old', '-new'])}." \
           f"{random.choice(WORDS)}.{random.choice(TLDS)}"


def rnd_path():
    depth = random.randint(1, 4)
    parts = [random.choice(WORDS) for _ in range(depth)]
    ext = random.choice(["", "", ".conf", ".json", ".log", ".sh", ".py", ".txt", ".yaml", ".service", ".zip", ".tar.gz"])
    return random.choice(["/", "./", "~/", "/etc/", "/var/log/", "/opt/", "C:\\dev\\", ""]) + "/".join(parts) + ext


def rnd_ip():
    return f"{random.choice([10, 172, 192, 45, 91, 185])}.{random.randint(0, 255)}." \
           f"{random.randint(0, 255)}.{random.randint(1, 254)}"


def gen_terminal(n):
    out = []
    for _ in range(n):
        parts = [random.choice(CMDS)]
        for _ in range(random.randint(0, 3)):
            r = random.random()
            if r < 0.35:
                parts.append(random.choice(FLAGS))
            elif r < 0.6:
                parts.append(random.choice(WORDS))
            elif r < 0.75:
                parts.append(rnd_path())
            elif r < 0.85:
                parts.append(rnd_domain())
            elif r < 0.92:
                parts.append(rnd_ip() + random.choice(["", ":" + str(random.randint(22, 65535))]))
            else:
                parts.append(str(random.randint(0, 9999)))
        if random.random() < 0.15:
            parts += [random.choice(["|", "&&", ">", ">>", "2>&1", ";"]), random.choice(CMDS),
                      random.choice(FLAGS + WORDS)]
        out.append(" ".join(parts))
    return out


def gen_config(n):
    """Строки конфигов: key value / key = value / json-подобные."""
    out = []
    for _ in range(n):
        k = random.choice(WORDS)
        v = random.choice([random.choice(WORDS), rnd_domain(), rnd_ip(), str(random.randint(0, 65535)), rnd_path()])
        out.append(random.choice([f"{k} {v}", f"{k} = {v}", f"{k}: {v}", f'"{k}": "{v}",', f"{k}={v}", f"set {k} {v}"]))
    return out


# ------------------------------------------------------------------ код

CODE_EXT = {".swift", ".cs", ".py", ".sh", ".ps1", ".js", ".ts", ".go", ".rs", ".kt", ".java", ".c", ".h", ".cpp",
            ".json", ".yaml", ".yml", ".toml", ".md"}


def scan_code(root, limit):
    out = []
    ident = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|[А-Яа-яЁё]+")
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if not d.startswith(".") and d not in ("node_modules", "build", "bin", "obj", "Resources", "data")]
        for name in fn:
            if os.path.splitext(name)[1].lower() not in CODE_EXT:
                continue
            try:
                with open(os.path.join(dp, name), encoding="utf-8", errors="ignore") as f:
                    for line in f:
                        toks = ident.findall(line)
                        if 2 <= len(toks) <= 30:
                            out.append(" ".join(toks))
                            if len(out) >= limit:
                                return out
            except OSError:
                pass
    return out


# ------------------------------------------------------------------ личное

def load_personal():
    path = os.path.join(DATA, "personal.txt")
    lines, words = [], []
    if not os.path.exists(path):
        return lines, words
    with open(path, encoding="utf-8") as f:
        for raw in f:
            raw = raw.rstrip("\n")
            if not raw or raw.startswith("#"):
                continue
            parts = raw.split("\t")
            if len(parts) < 2:
                continue
            lang, text = parts[0].strip(), parts[1].strip()
            app = parts[2].strip() if len(parts) > 2 and parts[2].strip() in qsnet.APPS else "other"
            if lang not in ("ru", "en"):
                continue
            if " " in text:
                lines.append((app, 20.0, text))
            else:
                words.append((lang, 20.0, text))
    return lines, words


def load_learned(path):
    words = []
    if not path or not os.path.exists(path):
        return words
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    # stop: слово как набрано — и есть правильное → язык = его алфавит
    for w in d.get("stop", []):
        lang = qsnet.word_lang(w)
        if lang and qsnet.to_keys(w):
            words.append((lang, 50.0, w))
    # force: набрано не в той раскладке → имелся в виду другой язык
    for w in d.get("force", []):
        lang = qsnet.word_lang(w)
        if lang and qsnet.to_keys(w):
            words.append(("en" if lang == "ru" else "ru", 50.0, w))
    return words


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sentences", type=int, default=400_000, help="предложений Tatoeba на язык")
    ap.add_argument("--freq", type=int, default=30_000, help="частотных слов на язык")
    ap.add_argument("--terminal", type=int, default=80_000)
    ap.add_argument("--config", type=int, default=20_000)
    ap.add_argument("--code-dir", default=os.path.dirname(HERE), help="каталог с кодом для скана (app=code)")
    ap.add_argument("--code", type=int, default=40_000, help="строк кода максимум")
    ap.add_argument("--learned", default=os.path.expanduser("~/Library/Application Support/QSwitcher/learned.json"))
    ap.add_argument("--extra-ru", action="append", default=[], help="свой файл предложений RU (по строке)")
    ap.add_argument("--extra-en", action="append", default=[], help="свой файл предложений EN (по строке)")
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    random.seed(a.seed)
    os.makedirs(DATA, exist_ok=True)

    corpus = []   # (app, weight, text)
    words = []    # (lang, weight, word)

    log("Предложения (Tatoeba + свои)…")
    for lang in ("ru", "en"):
        sents = load_tatoeba(lang, a.sentences)
        for path in (a.extra_ru if lang == "ru" else a.extra_en):
            with open(path, encoding="utf-8", errors="ignore") as f:
                sents += [l.strip() for l in f if 2 <= len(l.split()) <= 25]
        log(f"  {lang}: {len(sents)} предложений")
        for s in sents:
            app = random.choices(["other", "chat", "browser", "code", "terminal"],
                                 weights=[5, 4, 3, 0.4, 0.3])[0]
            corpus.append((app, 1.0, s))
        if lang == "ru":
            # русские коммит-сообщения и комментарии в терминале/коде — чтобы terminal ≠ «всегда EN»
            for s in random.sample(sents, min(len(sents) // 40, 10_000)):
                corpus.append(("terminal", 1.0, f'git commit -m "{s}"'))
                corpus.append(("code", 1.0, "// " + s))
            for _ in range(3000):
                corpus.append(("terminal", 1.0, 'git commit -m "' + " ".join(random.sample(RU_COMMIT, random.randint(2, 5))) + '"'))

    log("Частотные списки…")
    for lang in ("ru", "en"):
        fw = load_freq(lang, a.freq)
        log(f"  {lang}: {len(fw)} слов")
        import math
        for w, n in fw:
            words.append((lang, 1.0 + math.log10(1 + n), w))

    log("Терминал/конфиги (синтетика)…")
    for s in gen_terminal(a.terminal):
        corpus.append(("terminal", 1.0, s))
    for s in gen_config(a.config):
        corpus.append((random.choice(["code", "terminal", "other"]), 1.0, s))

    log(f"Код из {a.code_dir}…")
    code = scan_code(a.code_dir, a.code)
    log(f"  {len(code)} строк")
    for s in code:
        corpus.append(("code", 0.7, s))

    log("Личное…")
    pl, pw = load_personal()
    lw = load_learned(a.learned)
    log(f"  personal.txt: {len(pl)} фраз, {len(pw)} слов; learned.json: {len(lw)} слов")
    corpus += pl
    words += pw + lw

    random.shuffle(corpus)
    with open(os.path.join(DATA, "corpus.tsv"), "w", encoding="utf-8") as f:
        for app, w, text in corpus:
            f.write(f"{app}\t{w:g}\t{text.replace(chr(9), ' ')}\n")
    with open(os.path.join(DATA, "words.tsv"), "w", encoding="utf-8") as f:
        for lang, w, word in words:
            f.write(f"{lang}\t{w:g}\t{word}\n")
    log(f"✅ corpus.tsv: {len(corpus)} строк, words.tsv: {len(words)} слов → {DATA}")


if __name__ == "__main__":
    main()
