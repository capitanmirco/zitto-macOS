"""Colours and widget styles of the window."""

from __future__ import annotations

import tkinter as tk
from tkinter import ttk

BG, PANEL, BUTTON, HOVER, EDGE = "#14171c", "#1b1f26", "#262c36", "#343c49", "#2a303a"
TEXT, DIM, ACCENT, BAD = "#e6e9ee", "#8a93a1", "#f5c451", "#ff7a7a"
COLORS = {"lead": "#ff7a90", "backing": "#ff9ecb", "drums": "#ffb454", "bass": "#8bd450",
          "guitar": "#4cc9f0", "piano": "#b794f6", "wind": "#5eead4", "other": "#9fb0c3",
          "kick": "#e8923a", "snare": "#ffc272", "toms": "#f2a65a", "cymbals": "#ffdcae"}


def apply(root: tk.Tk, k: float) -> None:
    """`k`: pixels of this display for each pixel of a 96 dpi one."""
    def px(n):
        return round(n * k)

    root.configure(bg=BG)
    style = ttk.Style(root)
    style.theme_use("clam")
    style.configure("TProgressbar", background=ACCENT, troughcolor=BUTTON, bordercolor=BUTTON,
                    lightcolor=ACCENT, darkcolor=ACCENT, thickness=px(6))
    style.configure("Horizontal.TScale", background=DIM, troughcolor=BUTTON, bordercolor=PANEL,
                    lightcolor=DIM, darkcolor=DIM, sliderlength=px(12))
    style.map("Horizontal.TScale", background=[("active", TEXT)])
    for name in ("Horizontal.TScrollbar", "Vertical.TScrollbar"):
        style.configure(name, background=BUTTON, troughcolor=BG, bordercolor=BG,
                        arrowcolor=DIM, lightcolor=BUTTON, darkcolor=BUTTON)
        style.map(name, background=[("active", HOVER), ("disabled", PANEL)])
    style.configure("TCombobox", fieldbackground=BUTTON, background=BUTTON, foreground=TEXT,
                    arrowcolor=TEXT, bordercolor=EDGE, lightcolor=BUTTON, darkcolor=BUTTON)
    style.map("TCombobox", fieldbackground=[("readonly", BUTTON)], foreground=[("readonly", TEXT)],
              selectbackground=[("readonly", BUTTON)], selectforeground=[("readonly", TEXT)])
    for option, value in (("background", BUTTON), ("foreground", TEXT),
                          ("selectBackground", ACCENT), ("selectForeground", BG)):
        root.option_add(f"*TCombobox*Listbox.{option}", value)
    style.configure("Treeview", background=PANEL, fieldbackground=PANEL, foreground=TEXT, bordercolor=PANEL,
                    lightcolor=PANEL, darkcolor=PANEL, rowheight=px(26), font=("Segoe UI", 10), indent=px(14))
    style.map("Treeview", background=[("selected", HOVER)], foreground=[("selected", TEXT)])
    style.layout("Treeview", [("Treeview.treearea", {"sticky": "nswe"})])


def button(parent, text: str, command, k: float, width: int | None = None) -> tk.Button:
    return tk.Button(parent, text=text, command=command, width=width, bg=BUTTON, fg=TEXT, relief="flat", bd=0,
                     activebackground=HOVER, activeforeground=TEXT, disabledforeground=DIM, font=("Segoe UI", 10),
                     padx=round(10 * k), pady=round(4 * k), takefocus=0, cursor="hand2")
