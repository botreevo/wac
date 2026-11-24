"""The wac server against git's own servers, on the same repositories, with an unmodified git as the client.

    python3 bench/bench.py [--runs N] [--repos a,b,c] [--source URL-PREFIX]

Three servers serve one directory of bare repositories, one after another:

- **wac** — `dist/gitserve.wasm` (build it first: `wac task build`), with `--anonymous-push`;
- **http-backend** — git's CGI smart-HTTP server behind `bench/http_backend.py`;
- **git daemon** — git's native `git://` server, the floor: no HTTP at all.

For each repository and server: `ls-remote` latency, a full clone, an incremental fetch of the newest commits,
and a push of those commits. Each is the median of `--runs` runs. Server CPU is the server process's own time
plus its reaped children's (http-backend and git daemon run git in children); memory is the peak resident
size of the server's process tree, sampled every 20 ms.

Every result is checked, not just timed: a clone must pass `git fsck` and name the source's head, a fetch and a
push must move the ref to the right commit. A server that is fast because it did less shows up as a failure.
"""

import argparse
import os
import shutil
import statistics
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
TICK = os.sysconf("SC_CLK_TCK")
PAGE = os.sysconf("SC_PAGE_SIZE")


def sh(*args, cwd=None, check=True, env=None, quiet=True):
    r = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(args)}: {r.stderr.strip()}")
    return r.stdout.strip()


def git(*args, cwd=None, check=True):
    return sh("git", *args, cwd=cwd, check=check, env=CLIENT_ENV)


CLIENT_ENV = dict(os.environ, GIT_TERMINAL_PROMPT="0", no_proxy="127.0.0.1,localhost", NO_PROXY="127.0.0.1,localhost",
                  GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="b", GIT_AUTHOR_EMAIL="b@b", GIT_COMMITTER_NAME="b",
                  GIT_COMMITTER_EMAIL="b@b")
# A plain-HTTP proxy would carry the localhost requests; HTTPS_PROXY stays, for fetching the sources.
for k in ("http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY"):
    CLIENT_ENV.pop(k, None)


# ── The server's process tree: CPU and memory ────────────────────────────────

def stat(pid):
    with open(f"/proc/{pid}/stat") as f:
        parts = f.read().rsplit(")", 1)[1].split()
    # After the command: state ppid … utime(14) stime(15) cutime(16) cstime(17), counted from field 3.
    return int(parts[1]), sum(int(x) for x in parts[11:15])


def cpu(pid):
    return stat(pid)[1] / TICK


def tree_rss(root):
    children = {}
    for p in os.listdir("/proc"):
        if p.isdigit():
            try:
                children.setdefault(stat(int(p))[0], []).append(int(p))
            except (FileNotFoundError, ProcessLookupError, IndexError):
                pass
    total, todo = 0, [root]
    while todo:
        p = todo.pop()
        try:
            with open(f"/proc/{p}/statm") as f:
                total += int(f.read().split()[1]) * PAGE
        except (FileNotFoundError, ProcessLookupError):
            pass  # a child that exited between listing and reading
        todo.extend(children.get(p, []))
    return total


class Sampler:
    def __init__(self, pid):
        self.pid, self.peak, self.stop = pid, 0, False

    def __enter__(self):
        def run():
            while not self.stop:
                self.peak = max(self.peak, tree_rss(self.pid))
                time.sleep(0.02)
        self.t = threading.Thread(target=run, daemon=True)
        self.t.start()
        return self

    def __exit__(self, *a):
        self.stop = True
        self.t.join()


def reap(server):
    """Make the server collect its finished children, so their CPU time reaches its counters.

    git daemon reaps lazily — at the top of its accept loop — so a child's time is counted only once another
    connection arrives. One that connects and goes away is that connection; its own child does nothing.
    """
    import socket
    time.sleep(0.05)
    try:
        socket.create_connection(("127.0.0.1", server.port), 1).close()
    except OSError:
        pass
    time.sleep(0.15)


def measure(server, fn):
    """Run `fn`, answering (wall seconds, server CPU seconds, peak server RSS bytes)."""
    reap(server)
    c0 = cpu(server.pid)
    with Sampler(server.pid) as s:
        t0 = time.perf_counter()
        fn()
        wall = time.perf_counter() - t0
    reap(server)
    return wall, cpu(server.pid) - c0, s.peak


# ── Servers ──────────────────────────────────────────────────────────────────

def wait_port(port):
    import socket
    for _ in range(300):
        try:
            socket.create_connection(("127.0.0.1", port), 0.2).close()
            return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError(f"nothing listening on {port}")


def start(kind, root, port):
    if kind == "wac":
        wasm = os.path.join(REPO, "dist", "gitserve.wasm")
        if not os.path.exists(wasm):
            sys.exit("bench: build the server first — wac task build")
        p = subprocess.Popen(["wac", wasm, root, "--port", str(port), "--anonymous-push"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        url = f"http://127.0.0.1:{port}"
    elif kind == "http-backend":
        p = subprocess.Popen([sys.executable, os.path.join(HERE, "http_backend.py"), root, str(port)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        url = f"http://127.0.0.1:{port}"
    else:
        p = subprocess.Popen(["git", "daemon", "--reuseaddr", "--export-all", "--enable=receive-pack",
                              f"--base-path={root}", "--listen=127.0.0.1", f"--port={port}", root],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        url = f"git://127.0.0.1:{port}"
    wait_port(port)
    p.port = port
    return p, url


# ── Fixtures ─────────────────────────────────────────────────────────────────

def pack_bytes(gitdir):
    d = os.path.join(gitdir, "objects", "pack")
    return sum(os.path.getsize(os.path.join(d, f)) for f in os.listdir(d) if f.endswith(".pack"))


def prepare(work, source, name, back):
    """The source as a bare repository, and the same `back` commits behind, as a client and as a server."""
    src = os.path.join(work, "src", f"{name}.git")
    if not os.path.exists(src):
        git("clone", "-q", "--bare", f"{source}/{name}.git", src)
    branch = git("symbolic-ref", "--short", "HEAD", cwd=src)
    head = git("rev-parse", branch, cwd=src)
    depth = int(git("rev-list", "--count", "--first-parent", branch, cwd=src))
    back = min(back, depth - 1)
    old = git("rev-parse", f"{branch}~{back}", cwd=src)
    behind = os.path.join(work, "src", f"{name}-behind.git")
    if not os.path.exists(behind):
        git("clone", "-q", "--bare", "--no-local", "--single-branch", "--branch", branch, src, behind)
        git("update-ref", f"refs/heads/{branch}", old, cwd=behind)
        for ref in git("for-each-ref", "--format=%(refname)", "refs/tags", cwd=behind).split():
            git("update-ref", "-d", ref, cwd=behind)
        git("reflog", "expire", "--expire=now", "--all", cwd=behind)
        git("gc", "-q", "--prune=now", cwd=behind)
    for repo in (src, behind):
        git("config", "http.receivepack", "true", cwd=repo)
        git("config", "daemon.receivepack", "true", cwd=repo)
    objects = int(git("rev-list", "--objects", "--all", "--count", cwd=src))
    return dict(name=name, src=src, behind=behind, branch=branch, head=head, old=old, back=back,
                objects=objects, size=pack_bytes(src))


# ── The operations ───────────────────────────────────────────────────────────

def run_all(kind, root, port, fx, runs, work):
    server, url = start(kind, root, port)
    out = {}
    try:
        repo_url = f"{url}/{fx['name']}.git"

        def ls_remote():
            for _ in range(10):
                git("ls-remote", repo_url)

        samples = [measure(server, ls_remote) for _ in range(runs)]
        out["ls-remote"] = [(w / 10, c / 10, m) for w, c, m in samples]

        clones = []
        for i in range(runs):
            dest = os.path.join(work, "c", f"{kind}-{fx['name']}-{i}")
            shutil.rmtree(dest, ignore_errors=True)
            clones.append(measure(server, lambda: git("clone", "-q", "--bare", repo_url, dest)))
            git("fsck", "--strict", "--no-dangling", cwd=dest)
            assert git("rev-parse", fx["branch"], cwd=dest) == fx["head"], "clone has the wrong head"
            out["clone-bytes"] = pack_bytes(dest)
            shutil.rmtree(dest)
        out["clone"] = clones

        fetches = []
        for i in range(runs):
            dest = os.path.join(work, "c", f"{kind}-{fx['name']}-fetch-{i}")
            shutil.rmtree(dest, ignore_errors=True)
            git("clone", "-q", "--bare", "--no-local", fx["behind"], dest)
            before = pack_bytes(dest)
            fetches.append(measure(server, lambda: git("fetch", "-q", repo_url,
                                                       f"+refs/heads/{fx['branch']}:refs/heads/{fx['branch']}", cwd=dest)))
            assert git("rev-parse", fx["branch"], cwd=dest) == fx["head"], "fetch did not arrive"
            git("fsck", "--no-dangling", cwd=dest)
            out["fetch-bytes"] = pack_bytes(dest) - before
            shutil.rmtree(dest)
        out["fetch"] = fetches

        pushes = []
        client = os.path.join(work, "c", f"{kind}-{fx['name']}-pusher")
        shutil.rmtree(client, ignore_errors=True)
        git("clone", "-q", "--bare", "--no-local", "--single-branch", "--branch", fx["branch"], fx["src"], client)
        for i in range(runs):
            target = f"push-{fx['name']}-{kind}-{i}.git"
            shutil.copytree(fx["behind"], os.path.join(root, target))
            pushes.append(measure(server, lambda: git("push", "-q", f"{url}/{target}",
                                                      f"{fx['branch']}:{fx['branch']}", cwd=client)))
            there = os.path.join(root, target)
            assert git("rev-parse", fx["branch"], cwd=there) == fx["head"], "push did not arrive"
            git("fsck", "--no-dangling", cwd=there)
            shutil.rmtree(there)
        shutil.rmtree(client)
        out["push"] = pushes
    finally:
        server.terminate()
        server.wait()
        time.sleep(0.2)
    return out


def med(samples, i):
    return statistics.median(s[i] for s in samples)


def fmt_s(x):
    return f"{x * 1000:.0f} ms" if x < 1 else f"{x:.2f} s"


def fmt_b(x):
    return f"{x / 1048576:.1f} MB" if x >= 1048576 else f"{x / 1024:.0f} KB"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--repos", default="wac-sudoku,wacuum,wac")
    ap.add_argument("--source", default="https://git.voltrevo.com")
    ap.add_argument("--back", type=int, default=50, help="commits the fetch and push carry")
    ap.add_argument("--servers", default="wac,http-backend,git-daemon")
    a = ap.parse_args()

    work = os.path.join(HERE, "out", "work")
    root = os.path.join(work, "root")
    os.makedirs(os.path.join(work, "c"), exist_ok=True)
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(root)

    lines = []
    def say(s=""):
        print(s, flush=True)
        lines.append(s)

    say("# wac git server against git's servers")
    say()
    say(f"- client and servers: git {sh('git', '--version').split()[-1]}, node {sh('node', '--version')}, "
        f"{os.cpu_count()} CPUs, {a.runs} runs each (median)")
    say(f"- wac at {open(os.path.join(REPO, 'WAC_COMMIT')).read().strip()[:12]}, this repository at "
        f"{sh('git', '-C', REPO, 'rev-parse', '--short', 'HEAD', check=False) or 'uncommitted'}")
    say("- **wac**: `dist/gitserve.wasm` on the Node host · **http-backend**: git's CGI server behind a minimal "
        "Python bridge · **git daemon**: git's native `git://` server, no HTTP")
    say()

    for name in a.repos.split(","):
        fx = prepare(work, a.source, name, a.back)
        os.symlink(fx["src"], os.path.join(root, f"{name}.git"))
        say(f"## {name} — {fx['objects']:,} objects, {fmt_b(fx['size'])} packed; fetch and push carry {fx['back']} commits")
        say()
        results = {}
        port = 21000
        for kind in a.servers.split(","):
            port += 1
            results[kind] = run_all(kind, root, port, fx, a.runs, work)
        say("| | server | wall | server CPU | server peak RSS | pack received |")
        say("|---|---|---:|---:|---:|---:|")
        for op, label, key in (("ls-remote", "ls-remote (each)", None), ("clone", "full clone", "clone-bytes"),
                               ("fetch", "incremental fetch", "fetch-bytes"), ("push", "push", None)):
            for kind, r in results.items():
                s = r[op]
                # git daemon's children are not counted in its CPU time however it is coaxed to reap them, so
                # its column would read zero; it is reported as unmeasured rather than as free.
                cpu_s = "n/a" if kind == "git-daemon" else fmt_s(med(s, 1))
                say(f"| {label} | {kind} | {fmt_s(med(s, 0))} | {cpu_s} | {fmt_b(med(s, 2))} | "
                    f"{fmt_b(r[key]) if key else ''} |")
        say()

    os.makedirs(os.path.join(HERE, "out"), exist_ok=True)
    with open(os.path.join(HERE, "out", "results.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
