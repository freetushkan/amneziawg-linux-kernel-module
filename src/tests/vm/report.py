#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Turn VM test runs into reports.

  report.py collect --log console.log --kernel K [--meta key=value ...] --out results.json
      parse the console log of src/tests/vm/run.sh into JSON
  report.py markdown results.json ...
      matrix for the GitHub Actions job summary
  report.py site --site DIR --run-id ID --url URL results.json ...
      add a run to a GitHub Pages tree: DIR/runs/ID/, DIR/index.html,
      DIR/history.json and shields.io endpoint badges in DIR/badge/

Standard library only.
"""

import argparse
import datetime
import html
import json
import os
import re
import shutil
import sys

MODES = [("strict", "Clients on upstream", "Upstream AmneziaWG built as a second module: accepts only its own format, does not announce itself."),
         ("own", "Clients on this module", "Both sides run the fallback.")]

# Columns of the client matrix: (key prefix, title, subtitle, explanation)
COLUMNS = [
    ("t1.connect", "Connects", "client → server", "The client initiates and reaches the server."),
    ("t1.detect", "Detected", "from its handshake", "The server recognises the client's protocol from its handshake."),
    ("t2.loss", "No loss", "300 pings, ambiguous headers", "300 pings without loss although wide H ranges make many packets fit several formats."),
    ("t3.reach", "Server first", "server → new client", "The server initiates to a client it has never heard from (compat=2) and gets through."),
    ("t3.detect", "Detected", "from its answer", "The server recognises the protocol from the client's answer."),
    ("t4", "compat=0", "upstream behaviour", "With the fallback off only the full-protocol client may connect, as with upstream."),
]
# Checks not tied to one client: (key, title, modes shown in). The two-host
# test runs this module on both sides whatever the clients are, so it is
# shown once.
GLOBAL = [
    ("t1.own_format", "Server answers every client in the client's own format", ("strict", "own")),
    ("t3.own_format", "Same when the server initiates", ("strict", "own")),
    ("t5.reach", "Two hosts running this fork: the client reaches a server that restarted while it was probing", ("own",)),
    ("t5.full", "Two hosts running this fork: neither is left on an older format", ("own",)),
]
KEEP_RUNS = 100  # runs kept on the site

ICON = {"pass": "✅", "fail": "❌", "known": "⚠️", None: "➖"}
RANK = {"fail": 3, "known": 2, "pass": 1, None: 0}

PROBLEM = re.compile(r"WARNING: CPU|-+\[ cut here \]|BUG:|Oops|Call Trace|general protection fault|KASAN|refcount_t:|list_(add|del) corruption")


# ------------------------------------------------------------------ collect

def section(lines, name):
    out, inside = [], False
    for l in lines:
        if l.startswith("@@ BEGIN " + name):
            inside = True
        elif l.startswith("@@ END " + name):
            return out, l
        elif inside:
            out.append(l)
    return out, None


def collect(args):
    with open(args.log, errors="replace") as f:
        lines = [l.rstrip("\n") for l in f]
    run = {"kernel": args.kernel, "modes": {}, "clients": {}, "problems": [], "load_errors": []}
    for kv in args.meta or []:
        k, _, v = kv.partition("=")
        run[k] = v
    for mode, _, _ in MODES:
        body, end = section(lines, mode)
        results = {}
        for l in body:
            if l.startswith("@@C "):
                _, name, rest = l.split(" ", 2)
                title, _, details = rest.partition("|")
                run["clients"][name] = {"title": title, "details": details}
            elif l.startswith("@@R "):
                parts = l.split(" ", 3)
                if len(parts) >= 3:
                    results[parts[1]] = {"status": parts[2], "detail": parts[3] if len(parts) > 3 else ""}
        rc = None
        if end:
            m = re.search(r"rc=(\d+)", end)
            rc = int(m.group(1)) if m else None
        run["modes"][mode] = {"results": results, "finished": end is not None, "rc": rc}
    dmesg, _ = section(lines, "dmesg")
    for i, l in enumerate(dmesg):
        if PROBLEM.search(l):
            run["problems"].append("\n".join(dmesg[i:i + 12]))
    run["load_errors"] = [l for l in lines if l.startswith("@@ insmod")]
    run["ok"] = ok(run)
    with open(args.out, "w") as f:
        json.dump(run, f, indent=1)
    return 0 if run["ok"] else 1


def ok(run):
    for m in run["modes"].values():
        if not m["finished"] or not m["results"] or any(r["status"] == "fail" for r in m["results"].values()):
            return False
    return not run["problems"] and not run["load_errors"]


def totals(runs):
    t = {"pass": 0, "fail": 0, "known": 0}
    for run in runs:
        for m in run["modes"].values():
            for r in m["results"].values():
                t[r["status"]] = t.get(r["status"], 0) + 1
    return t


def clients(runs):
    names = []
    for run in runs:
        for c in run["clients"]:
            if c not in names:
                names.append(c)
    return names


def client_info(runs, c):
    for run in runs:
        if c in run["clients"]:
            return run["clients"][c]
    return {"title": c, "details": ""}


def short_kernel(k):
    m = re.match(r"(\d+\.\d+)\.\d+-(\d+)", k)
    return f"{m.group(1)}" if m else k


def cell(runs, mode, key):
    """Status per kernel for one check: [(kernel, status, detail)]."""
    out = []
    for run in runs:
        r = run["modes"].get(mode, {}).get("results", {}).get(key)
        out.append((run["kernel"], r["status"] if r else None, r["detail"] if r else ""))
    return out


def worst(statuses):
    return max(statuses, key=lambda s: RANK[s])


def working_clients(runs):
    """Clients with no failed check in any mode and kernel."""
    good = 0
    names = clients(runs)
    for c in names:
        bad = False
        for run in runs:
            for m in run["modes"].values():
                for k, r in m["results"].items():
                    if k.endswith("." + c) or k == "t4." + c:
                        bad |= r["status"] == "fail"
        good += not bad
    return good, len(names)


# ------------------------------------------------------------------ markdown

def md_cell(entries):
    statuses = [s for _, s, _ in entries]
    if len(set(statuses)) == 1:
        return ICON[statuses[0]]
    return " ".join(f"{short_kernel(k)} {ICON[s]}" for k, s, _ in entries)


def markdown(args):
    runs = [json.load(open(p)) for p in args.results]
    runs.sort(key=lambda r: r["kernel"])
    t = totals(runs)
    good, n = working_clients(runs)
    allok = all(r["ok"] for r in runs)
    out = []
    out.append(f"## {'✅' if allok else '❌'} Compatibility: {good}/{n} clients, "
               f"{t['pass']}/{t['pass'] + t['fail'] + t['known']} checks passed"
               + (f", {t['known']} known upstream issues" if t["known"] else ""))
    out.append("")
    meta = runs[0] if runs else {}
    out.append("Kernels: " + ", ".join(f"`{r['kernel']}`" for r in runs)
               + f" · this tree `{meta.get('tree', '?')}` · upstream `{meta.get('upstream', '?')}`"
               + f" · awg tools `{meta.get('tools', '?')}`")
    out.append("")
    for mode, title, about in MODES:
        out.append(f"### {title}")
        out.append("")
        out.append(f"_{about}_")
        out.append("")
        out.append("| Client | " + " | ".join(f"{c[1]}<br><sub>{c[2]}</sub>" for c in COLUMNS) + " |")
        out.append("|---|" + "---|" * len(COLUMNS))
        for c in clients(runs):
            info = client_info(runs, c)
            row = [f"**{info['title']}**<br><sub>{info['details']}</sub>"]
            for key, _, _, _ in COLUMNS:
                row.append(md_cell(cell(runs, mode, f"{key}.{c}")))
            out.append("| " + " | ".join(row) + " |")
        out.append("")
        for key, title_, shown in GLOBAL:
            entries = cell(runs, mode, key)
            if mode in shown and any(s for _, s, _ in entries):
                out.append(f"- {md_cell(entries)} {title_}")
        out.append("")
    notes = []
    for run in runs:
        for mode, title, _ in MODES:
            for k, r in sorted(run["modes"].get(mode, {}).get("results", {}).items()):
                if r["status"] != "pass":
                    notes.append(f"- {ICON[r['status']]} `{short_kernel(run['kernel'])}` {title.lower()}: {r['detail']}")
        for p in run["problems"]:
            notes.append(f"- ❌ `{run['kernel']}` kernel problem:\n```\n{p}\n```")
        for e in run["load_errors"]:
            notes.append(f"- ❌ `{run['kernel']}` {e[3:]}")
    if notes:
        out.append("<details><summary>Details</summary>\n")
        out += notes
        out.append("\n</details>\n")
    out.append("✅ passed · ❌ failed · ⚠️ known upstream issue (not caused by this tree) · ➖ not run")
    print("\n".join(out))
    return 0


# ------------------------------------------------------------------ html

CSS = """
:root { --ok:#1a7f37; --okbg:#dafbe1; --bad:#cf222e; --badbg:#ffebe9; --warn:#9a6700; --warnbg:#fff8c5;
        --fg:#1f2328; --mut:#656d76; --bd:#d0d7de; --bg:#ffffff; --head:#f6f8fa; }
@media (prefers-color-scheme: dark) {
  :root { --ok:#3fb950; --okbg:#12261e; --bad:#f85149; --badbg:#2d1214; --warn:#d29922; --warnbg:#272115;
          --fg:#e6edf3; --mut:#8d96a0; --bd:#30363d; --bg:#0d1117; --head:#161b22; } }
* { box-sizing: border-box; }
body { margin:0; font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif; color:var(--fg); background:var(--bg); }
main { max-width: 1180px; margin: 0 auto; padding: 32px 20px 64px; }
h1 { font-size: 26px; margin: 0 0 4px; } h2 { font-size: 19px; margin: 36px 0 6px; } h3 { font-size: 16px; margin: 24px 0 6px; }
a { color: inherit; }
.sub { color: var(--mut); margin: 0 0 18px; }
.hero { display:flex; gap:12px; flex-wrap:wrap; margin: 18px 0 8px; }
.stat { border:1px solid var(--bd); border-radius:10px; padding:12px 16px; min-width:150px; }
.stat b { display:block; font-size:22px; } .stat span { color: var(--mut); font-size: 13px; }
.stat.ok b { color: var(--ok); } .stat.bad b { color: var(--bad); } .stat.warn b { color: var(--warn); }
.meta { color: var(--mut); font-size: 13px; } .meta code { font-size: 12px; }
.wrap { overflow-x:auto; border:1px solid var(--bd); border-radius:10px; }
table { border-collapse: collapse; width:100%; }
th, td { padding: 9px 10px; border-bottom: 1px solid var(--bd); text-align: center; vertical-align: middle; }
th { background: var(--head); font-size: 13px; font-weight: 600; }
tr:last-child td { border-bottom: 0; }
td.client { text-align: left; min-width: 230px; } td.client small { display:block; color: var(--mut); font-size: 12px; }
td.s { font-size: 13px; white-space: nowrap; }
td.pass { background: var(--okbg); color: var(--ok); } td.fail { background: var(--badbg); color: var(--bad); }
td.known { background: var(--warnbg); color: var(--warn); } td.none { color: var(--mut); }
th small { display:block; font-weight: 400; color: var(--mut); }
ul.checks { list-style:none; padding:0; margin: 10px 0 0; } ul.checks li { margin: 4px 0; }
.legend { color: var(--mut); font-size: 13px; margin-top: 10px; }
details { margin-top: 14px; } pre { overflow-x:auto; background: var(--head); padding: 10px; border-radius: 8px; font-size: 12px; }
.hist td, .hist th { text-align: left; }
"""


def h(s):
    return html.escape(str(s))


def html_cell(entries):
    statuses = [s for _, s, _ in entries]
    w = worst(statuses)
    cls = {"pass": "pass", "fail": "fail", "known": "known", None: "none"}[w]
    tip = "\n".join(f"{k}: {s or 'not run'}{' - ' + d if d else ''}" for k, s, d in entries)
    if len(set(statuses)) == 1:
        body = ICON[w]
    else:
        body = "<br>".join(f"{h(short_kernel(k))} {ICON[s]}" for k, s, _ in entries)
    return f'<td class="s {cls}" title="{h(tip)}">{body}</td>'


def render_run(runs, url_base, history):
    t = totals(runs)
    good, n = working_clients(runs)
    allok = all(r["ok"] for r in runs)
    meta = runs[0] if runs else {}
    when = meta.get("date", "")
    p = []
    p.append(f"<h1>{'✅' if allok else '❌'} AmneziaWG compatibility</h1>")
    p.append(f'<p class="sub">Fallback for older AmneziaWG versions and WireGuard, tested in a VM against '
             f'current upstream. <a href="https://github.com/{h(meta.get("repo", ""))}/blob/master/FORK.md">What is this?</a></p>')
    p.append('<div class="hero">')
    p.append(f'<div class="stat {"ok" if good == n else "bad"}"><b>{good}/{n}</b><span>client generations work</span></div>')
    p.append(f'<div class="stat {"ok" if not t["fail"] else "bad"}"><b>{t["pass"]}/{t["pass"] + t["fail"] + t["known"]}</b><span>checks passed</span></div>')
    if t["known"]:
        p.append(f'<div class="stat warn"><b>{t["known"]}</b><span>known upstream issues</span></div>')
    p.append(f'<div class="stat"><b>{len(runs)}</b><span>kernels: {h(", ".join(short_kernel(r["kernel"]) for r in runs))}</span></div>')
    p.append("</div>")
    repo = meta.get("repo", "")
    tree = meta.get("tree", "?")
    p.append('<p class="meta">'
             + (f'{h(when)} · ' if when else "")
             + f'this tree <a href="https://github.com/{h(repo)}/commit/{h(meta.get("sha", tree))}"><code>{h(tree)}</code></a> · '
             f'upstream <code>{h(meta.get("upstream", "?"))}</code> · awg tools <code>{h(meta.get("tools", "?"))}</code>'
             + (f' · <a href="{h(meta["run_url"])}">workflow run</a>' if meta.get("run_url") else "")
             + " · kernels " + ", ".join(f"<code>{h(r['kernel'])}</code>" for r in runs) + "</p>")

    for mode, title, about in MODES:
        p.append(f"<h2>{h(title)}</h2><p class=\"sub\">{h(about)}</p>")
        p.append('<div class="wrap"><table><tr><th style="text-align:left">Client</th>'
                 + "".join(f'<th title="{h(expl)}">{h(t_)}<small>{h(sub)}</small></th>'
                           for _, t_, sub, expl in COLUMNS) + "</tr>")
        for c in clients(runs):
            info = client_info(runs, c)
            p.append(f'<tr><td class="client"><b>{h(info["title"])}</b><small>{h(info["details"])}</small></td>'
                     + "".join(html_cell(cell(runs, mode, f"{key}.{c}")) for key, _, _, _ in COLUMNS) + "</tr>")
        p.append("</table></div><ul class=\"checks\">")
        for key, title_, shown in GLOBAL:
            entries = cell(runs, mode, key)
            if mode in shown and any(s for _, s, _ in entries):
                tip = "\n".join(f"{k}: {s}{' - ' + d if d else ''}" for k, s, d in entries)
                body = ICON[worst([s for _, s, _ in entries])] if len({s for _, s, _ in entries}) == 1 else \
                    " ".join(f"{h(short_kernel(k))} {ICON[s]}" for k, s, _ in entries)
                p.append(f'<li title="{h(tip)}">{body} {h(title_)}</li>')
        p.append("</ul>")

    notes = []
    for run in runs:
        for mode, title, _ in MODES:
            for k, r in sorted(run["modes"].get(mode, {}).get("results", {}).items()):
                if r["status"] != "pass":
                    notes.append(f"<li>{ICON[r['status']]} <code>{h(short_kernel(run['kernel']))}</code> "
                                 f"{h(title.lower())}: {h(r['detail'])}</li>")
            m = run["modes"].get(mode, {})
            if not m.get("finished"):
                notes.append(f"<li>❌ <code>{h(run['kernel'])}</code> {h(title.lower())}: did not finish</li>")
        for pr in run["problems"]:
            notes.append(f"<li>❌ <code>{h(run['kernel'])}</code> kernel problem<pre>{h(pr)}</pre></li>")
        for e in run["load_errors"]:
            notes.append(f"<li>❌ <code>{h(run['kernel'])}</code> {h(e[3:])}</li>")
    if notes:
        p.append("<h2>Details</h2><ul>" + "".join(notes) + "</ul>")
    p.append('<p class="legend">✅ passed · ❌ failed · ⚠️ known upstream issue, not caused by this tree · ➖ not run. '
             'Hover a cell for per-kernel details.</p>')
    logs = [f'<a href="{h(url_base)}console-{h(r["kernel"])}.log">{h(short_kernel(r["kernel"]))} console log</a>' for r in runs]
    p.append('<p class="meta">' + " · ".join(logs + [f'<a href="{h(url_base)}results.json">results.json</a>']) + "</p>")

    if history is not None:
        p.append('<h2>History</h2><div class="wrap"><table class="hist"><tr><th>Date</th><th>Result</th><th>Checks</th>'
                 '<th>This tree</th><th>Upstream</th><th>Kernels</th></tr>')
        for e in history[:50]:
            p.append(f'<tr><td><a href="runs/{h(e["id"])}/">{h(e["date"])}</a></td><td>{"✅" if e["ok"] else "❌"}</td>'
                     f'<td>{e["pass"]}/{e["total"]}' + (f' · ⚠️ {e["known"]}' if e.get("known") else "") + '</td>'
                     f'<td><code>{h(e["tree"])}</code></td><td><code>{h(e["upstream"])}</code></td>'
                     f'<td>{h(", ".join(e["kernels"]))}</td></tr>')
        p.append("</table></div>")

    title = f"{'✅' if allok else '❌'} AmneziaWG compatibility: {good}/{n} clients"
    return (f'<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width, initial-scale=1"><title>{h(title)}</title>'
            f"<style>{CSS}</style></head><body><main>" + "\n".join(p) + "</main></body></html>\n")


def site(args):
    runs = [json.load(open(p)) for p in args.results]
    runs.sort(key=lambda r: r["kernel"])
    date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    for r in runs:
        r.setdefault("date", date)
    rundir = os.path.join(args.site, "runs", args.run_id)
    os.makedirs(rundir, exist_ok=True)
    with open(os.path.join(rundir, "results.json"), "w") as f:
        json.dump(runs, f, indent=1)
    for log in args.logs or []:
        shutil.copy(log, rundir)

    hist_path = os.path.join(args.site, "history.json")
    history = json.load(open(hist_path)) if os.path.exists(hist_path) else []
    t = totals(runs)
    good, n = working_clients(runs)
    meta = runs[0] if runs else {}
    entry = {"id": args.run_id, "date": date, "ok": all(r["ok"] for r in runs),
             "pass": t["pass"], "known": t["known"], "total": t["pass"] + t["fail"] + t["known"],
             "clients": [good, n], "tree": meta.get("tree", "?"), "upstream": meta.get("upstream", "?"),
             "kernels": [r["kernel"] for r in runs]}
    history = [e for e in history if e["id"] != args.run_id]
    history.insert(0, entry)
    for old in history[KEEP_RUNS:]:
        shutil.rmtree(os.path.join(args.site, "runs", old["id"]), ignore_errors=True)
    history = history[:KEEP_RUNS]
    with open(hist_path, "w") as f:
        json.dump(history, f, indent=1)

    with open(os.path.join(rundir, "index.html"), "w") as f:
        f.write(render_run(runs, "", None))
    with open(os.path.join(args.site, "index.html"), "w") as f:
        f.write(render_run(runs, f"runs/{args.run_id}/", history))
    with open(os.path.join(args.site, ".nojekyll"), "w"):
        pass

    badge = os.path.join(args.site, "badge")
    os.makedirs(badge, exist_ok=True)
    allok = entry["ok"]
    known = f" · ⚠ {t['known']}" if t["known"] else ""
    with open(os.path.join(badge, "compat.json"), "w") as f:
        json.dump({"schemaVersion": 1, "label": "compat",
                   "message": f"{good}/{n} clients · {t['pass']}/{entry['total']} checks{known}",
                   "color": "brightgreen" if allok else "red"}, f)
    with open(os.path.join(badge, "kernels.json"), "w") as f:
        json.dump({"schemaVersion": 1, "label": "tested on",
                   "message": " · ".join(short_kernel(r["kernel"]) for r in runs) or "none",
                   "color": "blue"}, f)
    with open(os.path.join(badge, "upstream.json"), "w") as f:
        json.dump({"schemaVersion": 1, "label": "upstream",
                   "message": meta.get("upstream", "?").split(" ")[0], "color": "informational"}, f)
    print(os.path.join(args.url.rstrip("/"), ""))
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect")
    c.add_argument("--log", required=True)
    c.add_argument("--kernel", required=True)
    c.add_argument("--meta", action="append")
    c.add_argument("--out", required=True)
    m = sub.add_parser("markdown")
    m.add_argument("results", nargs="+")
    s = sub.add_parser("site")
    s.add_argument("--site", required=True)
    s.add_argument("--run-id", required=True)
    s.add_argument("--url", default="")
    s.add_argument("--logs", nargs="*")
    s.add_argument("results", nargs="+")
    args = ap.parse_args()
    return {"collect": collect, "markdown": markdown, "site": site}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
