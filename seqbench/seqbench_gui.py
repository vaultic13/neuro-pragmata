"""seqbench -- batch-test sequence-hack prompt versions against an AI peer.

    py -3 seqbench_gui.py --url ws://127.0.0.1:8123

The bench plays the mod: it dials the listening peer, registers
pragmata_hack_sequence in one version's wording, forces a set of puzzles, and
times and scores each reply. See README.md.
"""
from __future__ import annotations

import argparse
import json
import os
import queue
import sys
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

import puzzles  # noqa: E402
import scoring  # noqa: E402
import sequence_texts as texts  # noqa: E402
import variants  # noqa: E402
from mod_mimic import RESULTS_DIR, BenchEvent, ModMimic, RunPlan  # noqa: E402

RATING_COLOURS = {
    "very good": "#1d7f47",
    "good": "#5b8f22",
    "risky": "#b06000",
    "fail": "#b32d2d",
    "timeout": "#8a3fb3",
    "warm-up": "#888888",
}
STATUS_COLOURS = {"connected": "#1d7f47", "connecting": "#b06000", "disconnected": "#b32d2d"}

SUMMARY_COLS = [
    ("group", "Group", 50), ("version", "Version", 230), ("trials", "Trials", 55), ("correct_pct", "Correct %", 75),
    ("pass_pct", "Pass %", 60), ("very good", "Very good", 75), ("good", "Good", 50),
    ("risky", "Risky", 50), ("fail", "Fail", 45), ("timeout", "Timeout", 60), ("median_ms", "Median ms", 80),
    ("mean_ms", "Mean ms", 70),
]
TRIAL_COLS = [
    ("n", "#", 45), ("version", "Version", 210), ("puzzle", "Puzzle", 95),
    ("sequence", "Sequence", 190), ("answer", "Answer", 190), ("ms", "ms", 60),
    ("rating", "Rating", 75), ("outcome", "Outcome", 95),
]
# Lower is better for these, so their first click sorts ascending.
ASCENDING_FIRST = {"group", "version", "median_ms", "mean_ms", "fail", "timeout"}

# What each summary column means, shown under the table.
SUMMARY_LEGEND = "\n".join((
    "Group / Version -- the mod's group number (mod_config.puzzle_sequence_group) and the bench's version id",
    "Trials -- scored forces for the version; warm-ups are not counted",
    "Correct % -- right answers at any speed",
    "Pass % -- right answers in under 3 s: the share that works in game",
    "Very good / Good / Risky -- right answers under 1.6 s / 2.2 s / 3 s",
    "Fail -- a wrong answer, or one refused without pressing (bad letter, distance, length)",
    "Timeout -- a right answer that took 3 s or more, or no reply at all",
    "Median / Mean ms -- force sent to reply received, over the replies that arrived",
    "Green row -- the best version: Pass %, then Correct %, then Very good, then median",
))


class BenchApp:
    def __init__(self, root: tk.Tk, args: argparse.Namespace) -> None:
        self.root = root
        root.title("seqbench - sequence hack prompt bench")
        root.geometry("1460x920")
        self.events: "queue.Queue[BenchEvent]" = queue.Queue()
        self.mimic = ModMimic(self.events)
        self.records: list[dict] = []
        self.out_dir: Optional[Path] = None
        self.expected = 0
        self.status_word = "disconnected"
        self.summary_sort = ("pass_pct", True)
        self.versions: list[variants.Version] = []

        self._build_top(args)
        body = ttk.Panedwindow(root, orient=tk.HORIZONTAL)
        body.pack(fill=tk.BOTH, expand=True, padx=8, pady=(0, 8))
        left = ttk.Frame(body)
        right = ttk.Panedwindow(body, orient=tk.VERTICAL)
        body.add(left, weight=0)
        body.add(right, weight=1)
        self._build_setup(left, args)
        self._build_results(right)
        self._refresh_versions()

        root.protocol("WM_DELETE_WINDOW", self._on_close)
        root.after(50, self._poll)
        if args.connect:
            self._toggle_connection()

    # -- layout ------------------------------------------------------------

    def _build_top(self, args: argparse.Namespace) -> None:
        top = ttk.Frame(self.root, padding=8)
        top.pack(fill=tk.X)
        ttk.Label(top, text="Peer").pack(side=tk.LEFT)
        self.url = tk.StringVar(value=args.url)
        ttk.Entry(top, textvariable=self.url, width=30).pack(side=tk.LEFT, padx=6)
        self.connect_button = ttk.Button(top, text="Connect", command=self._toggle_connection)
        self.connect_button.pack(side=tk.LEFT)
        self.status = tk.Label(top, text="disconnected", fg=STATUS_COLOURS["disconnected"],
                               font=("Segoe UI", 10, "bold"))
        self.status.pack(side=tk.LEFT, padx=10)
        ttk.Label(top, foreground="#666",
                  text="The peer listens (apitest: port 8123, Auto-answer on); the bench "
                       "dials it the way the sidecar does.").pack(side=tk.LEFT, padx=10)

    def _build_setup(self, left: ttk.Frame, args: argparse.Namespace) -> None:
        vf = ttk.LabelFrame(left, text="Groups to test", padding=8)
        vf.pack(fill=tk.X)
        # One checkbox per group. The grey line says which mod setting selects
        # it, so a result can be carried straight into mod_config.
        self.group_vars: list[tuple[variants.Group, tk.BooleanVar]] = []
        for row, group in enumerate(variants.GROUPS):
            var = tk.BooleanVar(value=True)
            ttk.Checkbutton(vf, text=f"{group.number}  {group.id}", variable=var,
                            command=self._refresh_versions).grid(
                row=row * 2, column=0, sticky="w", pady=(6 if row else 0, 0))
            default = " (default)" if group.number == variants.DEFAULT_GROUP else ""
            ttk.Label(vf, foreground="#666", wraplength=430, justify=tk.LEFT,
                      text=f"mod: {variants.mod_setting(group)}{default}\n{group.about}").grid(
                row=row * 2 + 1, column=0, sticky="w", padx=(22, 0))
            self.group_vars.append((group, var))

        self.version_count = ttk.Label(left, font=("Segoe UI", 9, "bold"))
        self.version_count.pack(anchor="w", pady=(8, 2))

        rf = ttk.LabelFrame(left, text="Run", padding=8)
        rf.pack(fill=tk.X, pady=8)
        self.set_size = tk.StringVar(value=str(args.set_size))
        self.seed = tk.StringVar(value=str(args.seed))
        self.repeats = tk.StringVar(value=str(args.repeats))
        self.cap = tk.StringVar(value=str(args.cap))
        self.gap = tk.StringVar(value="0.5")
        self.warmup = tk.BooleanVar(value=True)
        self.full_catalogue = tk.BooleanVar(value=True)

        ttk.Label(rf, text="Puzzle set").grid(row=0, column=0, sticky="w")
        ttk.Combobox(rf, textvariable=self.set_size, values=[str(s) for s in puzzles.SET_MIX],
                     width=5, state="readonly").grid(row=0, column=1, sticky="w")
        self.mix_label = ttk.Label(rf, foreground="#666")
        self.mix_label.grid(row=0, column=2, sticky="w", padx=6)
        ttk.Label(rf, text="Seed").grid(row=1, column=0, sticky="w")
        ttk.Spinbox(rf, textvariable=self.seed, from_=0, to=999999, width=8).grid(row=1, column=1, sticky="w")
        ttk.Label(rf, text="Repeats").grid(row=2, column=0, sticky="w")
        ttk.Spinbox(rf, textvariable=self.repeats, from_=1, to=100, width=8).grid(row=2, column=1, sticky="w")
        ttk.Label(rf, foreground="#666", text="each repeat re-rolls the set").grid(row=2, column=2, sticky="w", padx=6)
        ttk.Label(rf, text="Reply cap (s)").grid(row=3, column=0, sticky="w")
        ttk.Spinbox(rf, textvariable=self.cap, from_=3, to=120, increment=1, width=8).grid(row=3, column=1, sticky="w")
        ttk.Label(rf, foreground="#666", text="3 s is a timeout anyway; this only bounds the wait").grid(
            row=3, column=2, sticky="w", padx=6)
        ttk.Label(rf, text="Gap (s)").grid(row=4, column=0, sticky="w")
        ttk.Spinbox(rf, textvariable=self.gap, from_=0, to=10, increment=0.1, width=8).grid(row=4, column=1, sticky="w")
        ttk.Checkbutton(rf, text="Unscored warm-up force per version (first call and cache miss)",
                        variable=self.warmup, command=self._refresh_counts).grid(
            row=5, column=0, columnspan=3, sticky="w", pady=(4, 0))
        ttk.Checkbutton(rf, text="Register plan + rotate copies too (in-game catalogue size)",
                        variable=self.full_catalogue).grid(row=6, column=0, columnspan=3, sticky="w")
        self.trial_count = ttk.Label(rf, font=("Segoe UI", 9, "bold"))
        self.trial_count.grid(row=7, column=0, columnspan=3, sticky="w", pady=(6, 0))
        for var in (self.set_size, self.seed, self.repeats, self.cap, self.gap):
            var.trace_add("write", lambda *_: self._refresh_counts())

        buttons = ttk.Frame(left)
        buttons.pack(fill=tk.X)
        self.run_button = ttk.Button(buttons, text="Run", command=self._run)
        self.run_button.pack(side=tk.LEFT)
        self.stop_button = ttk.Button(buttons, text="Stop", command=self.mimic.stop_run, state=tk.DISABLED)
        self.stop_button.pack(side=tk.LEFT, padx=6)
        ttk.Button(buttons, text="Open results folder", command=self._open_results).pack(side=tk.LEFT)
        self.progress = ttk.Progressbar(left, maximum=1)
        self.progress.pack(fill=tk.X, pady=(8, 2))
        self.progress_label = ttk.Label(left, text="idle")
        self.progress_label.pack(anchor="w")

    def _build_results(self, right: ttk.Panedwindow) -> None:
        sf = ttk.Frame(right)
        right.add(sf, weight=1)
        ttk.Label(sf, text="Summary per version  (pass = correct in under 3 s; warm-ups not scored; "
                           "click a heading to sort)").pack(anchor="w")
        self.summary = self._tree(sf, SUMMARY_COLS, height=7, sort=True)
        self.summary.tag_configure("best", background="#d9f2e0")
        ttk.Label(sf, text=SUMMARY_LEGEND, foreground="#666", font=("Segoe UI", 8),
                  justify=tk.LEFT).pack(anchor="w", pady=(2, 0))

        tf = ttk.Frame(right)
        right.add(tf, weight=2)
        ttk.Label(tf, text="Trials").pack(anchor="w")
        self.trials = self._tree(tf, TRIAL_COLS, height=10)
        for rating, colour in RATING_COLOURS.items():
            self.trials.tag_configure(rating, foreground=colour)
        self.trials.bind("<<TreeviewSelect>>", lambda _e: self._show_trial())

        nb = ttk.Notebook(right)
        right.add(nb, weight=2)
        self.detail = self._text_tab(nb, "Trial detail", wrap="none")
        self.log = self._text_tab(nb, "Log", wrap="word")
        self.log.tag_configure("error", foreground="#b32d2d")

    def _tree(self, parent: ttk.Frame, cols, height: int, sort: bool = False) -> ttk.Treeview:
        frame = ttk.Frame(parent)
        frame.pack(fill=tk.BOTH, expand=True)
        tree = ttk.Treeview(frame, columns=[c for c, _, _ in cols], show="headings", height=height)
        for cid, title, width in cols:
            command = (lambda c=cid: self._sort_summary(c)) if sort else ""
            tree.heading(cid, text=title, command=command)
            left_aligned = cid in ("version", "puzzle", "sequence", "answer", "rating", "outcome")
            tree.column(cid, width=width, anchor="w" if left_aligned else "e",
                        stretch=cid in ("version", "answer"))
        bar = ttk.Scrollbar(frame, orient=tk.VERTICAL, command=tree.yview)
        tree.configure(yscrollcommand=bar.set)
        tree.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        bar.pack(side=tk.RIGHT, fill=tk.Y)
        return tree

    def _text_tab(self, nb: ttk.Notebook, title: str, wrap: str) -> tk.Text:
        frame = ttk.Frame(nb)
        nb.add(frame, text=title)
        text = tk.Text(frame, wrap=wrap, font=("Consolas", 10))
        ys = ttk.Scrollbar(frame, orient=tk.VERTICAL, command=text.yview)
        xs = ttk.Scrollbar(frame, orient=tk.HORIZONTAL, command=text.xview)
        text.configure(yscrollcommand=ys.set, xscrollcommand=xs.set)
        ys.pack(side=tk.RIGHT, fill=tk.Y)
        xs.pack(side=tk.BOTTOM, fill=tk.X)
        text.pack(fill=tk.BOTH, expand=True)
        return text

    # -- setup -------------------------------------------------------------

    def _refresh_versions(self) -> None:
        self.versions = [g.version for g, var in self.group_vars if var.get()]
        n = len(self.versions)
        self.version_count.configure(text=f"{n} group{'s' if n != 1 else ''} ticked")
        self._refresh_counts()

    def _read_plan(self) -> Optional[RunPlan]:
        try:
            size = int(self.set_size.get())
            seed = int(self.seed.get())
            repeats = int(self.repeats.get())
            cap = float(self.cap.get())
            gap = float(self.gap.get())
        except ValueError:
            return None
        if size not in puzzles.SET_MIX or repeats < 1 or cap <= 0 or gap < 0:
            return None
        return RunPlan(versions=list(self.versions), set_size=size, seed=seed,
                       repeats=repeats, warmup=self.warmup.get(),
                       full_catalogue=self.full_catalogue.get(), cap_s=cap, gap_s=gap)

    def _refresh_counts(self) -> None:
        plan = self._read_plan()
        if plan is None:
            self.trial_count.configure(text="check the run settings")
            return
        three, four = puzzles.SET_MIX[plan.set_size]
        self.mix_label.configure(text=f"{three} x 3-press (7x7) + {four} x 4-press (9x9)")
        forces = plan.scored_trials() + plan.warmups()
        minutes = forces * (2.0 + plan.gap_s + 0.1) / 60
        warm = f" + {plan.warmups()} warm-up" if plan.warmup else ""
        self.trial_count.configure(
            text=f"{len(plan.versions)} versions x {plan.set_size} puzzles x {plan.repeats} = "
                 f"{plan.scored_trials()} scored{warm}  (~{minutes:.1f} min at 2 s a reply)")

    # -- actions -----------------------------------------------------------

    def _toggle_connection(self) -> None:
        if self.status_word in ("connected", "connecting"):
            if self.mimic.running and not messagebox.askyesno(
                    "seqbench", "A run is in progress. Disconnect and stop it?"):
                return
            self.mimic.disconnect()
        else:
            self.mimic.connect(self.url.get().strip())

    def _run(self) -> None:
        plan = self._read_plan()
        if plan is None:
            messagebox.showerror("seqbench", "Check the puzzle set, seed, repeats, cap and gap.")
            return
        if not plan.versions:
            messagebox.showerror("seqbench", "No versions selected.")
            return
        if not self.mimic.connected:
            messagebox.showerror("seqbench", "Connect to a peer first.")
            return
        if self.mimic.start_run(plan):
            self.run_button.configure(state=tk.DISABLED)
            self.stop_button.configure(state=tk.NORMAL)

    def _open_results(self) -> None:
        path = self.out_dir or RESULTS_DIR
        path.mkdir(parents=True, exist_ok=True)
        os.startfile(path)  # noqa: S606 - Windows tool, opening a folder

    def _on_close(self) -> None:
        if self.mimic.running and not messagebox.askyesno("seqbench", "A run is in progress. Quit anyway?"):
            return
        self.mimic.disconnect()
        self.root.after(200, self.root.destroy)

    # -- events ------------------------------------------------------------

    def _poll(self) -> None:
        try:
            while True:
                self._handle(self.events.get_nowait())
        except queue.Empty:
            pass
        self.root.after(50, self._poll)

    def _handle(self, ev: BenchEvent) -> None:
        if ev.kind == "status":
            self.status_word = ev.data
            self.status.configure(text=ev.data, fg=STATUS_COLOURS.get(ev.data, "#333"))
            self.connect_button.configure(
                text="Disconnect" if ev.data in ("connected", "connecting") else "Connect")
            if ev.data == "disconnected":
                self.run_button.configure(state=tk.NORMAL)
                self.stop_button.configure(state=tk.DISABLED)
            self._log(ev.text)
        elif ev.kind == "log":
            self._log(ev.text)
        elif ev.kind == "error":
            self._log(ev.text, "error")
        elif ev.kind == "run_started":
            self.records.clear()
            self.trials.delete(*self.trials.get_children())
            self.summary.delete(*self.summary.get_children())
            self.out_dir = Path(ev.data["out_dir"])
            self.expected = ev.data["scored"] + ev.data["warmups"]
            self.progress.configure(maximum=max(1, self.expected), value=0)
            self.progress_label.configure(text=f"0 / {self.expected} forces")
            self._log(ev.text)
        elif ev.kind == "trial":
            self._add_trial(ev.data)
        elif ev.kind == "run_finished":
            self.run_button.configure(state=tk.NORMAL)
            self.stop_button.configure(state=tk.DISABLED)
            self.progress_label.configure(text=ev.text)
            self._log(ev.text)

    def _add_trial(self, rec: dict) -> None:
        self.records.append(rec)
        n = len(self.records)
        answer = scoring.reply_text(rec["cfg"], rec.get("raw_args"))
        ms = "" if rec["elapsed_ms"] is None else rec["elapsed_ms"]
        iid = str(n - 1)
        self.trials.insert("", tk.END, iid=iid, tags=(rec["rating"],), values=(
            n, rec["version"], rec["puzzle"], " ".join(rec["sequence"]), answer, ms,
            rec["rating"], rec["outcome"]))
        self.trials.see(iid)
        self.progress.configure(value=n)
        self.progress_label.configure(text=f"{n} / {self.expected} forces")
        self._refresh_summary()

    def _refresh_summary(self) -> None:
        rows = scoring.summarize(self.records)
        col, desc = self.summary_sort
        present = [r for r in rows if r.get(col) is not None]
        missing = [r for r in rows if r.get(col) is None]
        present.sort(key=lambda r: r[col], reverse=desc)
        rows = present + missing
        best = None
        if len(rows) > 1:
            best = max(rows, key=lambda r: (r["pass_pct"], r["correct_pct"], r["very good"],
                                            -(r["median_ms"] if r["median_ms"] is not None else 10 ** 9)))
        self.summary.delete(*self.summary.get_children())
        for r in rows:
            values = []
            for cid, _, _ in SUMMARY_COLS:
                v = r.get(cid)
                values.append("" if v is None else (f"{v:.1f}" if isinstance(v, float) else v))
            self.summary.insert("", tk.END, values=values, tags=("best",) if r is best else ())

    def _sort_summary(self, col: str) -> None:
        current, desc = self.summary_sort
        desc = (not desc) if col == current else (col not in ASCENDING_FIRST)
        self.summary_sort = (col, desc)
        self._refresh_summary()

    def _show_trial(self) -> None:
        sel = self.trials.selection()
        if not sel:
            return
        rec = self.records[int(sel[0])]
        action = texts.action_def(rec["cfg"])
        ms = "no reply" if rec["elapsed_ms"] is None else f"{rec['elapsed_ms']} ms"
        parts = [
            f"{rec['version']}   {rec['puzzle']}   repeat {rec['repeat'] + 1}",
            f"sequence: {' '.join(rec['sequence'])}",
            f"outcome: {rec['outcome']}   rating: {rec['rating']}   time: {ms}",
        ]
        if rec.get("late_reply_ms"):
            parts.append(f"late reply after {rec['late_reply_ms']} ms (told it was stale)")
        perm = rec.get("perm")
        parts += [
            "", "== RESULT SENT ==", rec["message"],
            "", "== REPLY ==",
            f"answer:   {scoring.reply_text(rec['cfg'], rec.get('raw_args'))}",
            f"expected: {scoring.truth_text(rec['cfg'], rec['sequence'], perm)}",
        ]
        misreads = scoring.letter_misreads(rec["cfg"], rec["sequence"], rec.get("raw_args"), perm)
        if misreads:
            parts.append("misread: " + "; ".join(misreads))
        parts += [
            f"raw: {rec.get('action')}  {rec.get('raw_args')}",
            "", "== QUERY ==", rec["query"],
            "", "== STATE ==", rec["state"],
            "", "== DESCRIPTION ==", action["description"],
            "", "== SCHEMA ==", json.dumps(action["schema"], indent=2),
        ]
        self.detail.delete("1.0", tk.END)
        self.detail.insert("1.0", "\n".join(parts))

    def _log(self, text: str, tag: Optional[str] = None) -> None:
        from datetime import datetime
        self.log.insert(tk.END, f"{datetime.now():%H:%M:%S} {text}\n", (tag,) if tag else ())
        self.log.see(tk.END)


def main() -> None:
    parser = argparse.ArgumentParser(description="Batch-test sequence-hack prompt versions.")
    parser.add_argument("--url", default="ws://127.0.0.1:8123", help="the listening peer")
    parser.add_argument("--connect", action="store_true", help="connect on startup")
    parser.add_argument("--set-size", type=int, default=5, choices=sorted(puzzles.SET_MIX))
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--cap", type=float, default=15.0, help="seconds to wait for a reply")
    args = parser.parse_args()
    root = tk.Tk()
    try:
        ttk.Style().theme_use("vista")
    except tk.TclError:
        pass
    BenchApp(root, args)
    root.mainloop()


if __name__ == "__main__":
    main()
